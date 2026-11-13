"""External sources: Gmail receipts (through a client another package provides) and Account
Aggregator (interface only: only a regulated entity may be an FIU).

Email bodies are untrusted data: they are only matched with regular expressions, never shown to a
model or followed. Receipts never count in totals; they lend a cleaner merchant name to the bank
debit they match (same amount, within three days).
"""

from __future__ import annotations

import hashlib
import re
from collections.abc import Callable
from datetime import date, datetime, timedelta
from typing import Protocol, runtime_checkable
from zoneinfo import ZoneInfo

from pydantic import BaseModel
from sqlalchemy import select

from app.core.clock import Clock
from app.core.errors import Unavailable
from app.core.money import to_paise
from app.core.types import CapabilityStatus, IntegrationLevel
from app.db.base import new_id
from app.db.session import SessionFactory
from app.finance.categories import CategoryConfigSource
from app.finance.formats import AmountError, parse_amount
from app.finance.importer import is_weak
from app.finance.models import FinanceAccount
from app.finance.models import FinanceTransaction as T
from app.finance.normalise import merchant_key, normalise
from app.schemas.security import Capability

GMAIL_SERVICE = "gmail_client"
RECEIPT_QUERY = 'subject:(receipt OR invoice OR "order confirmed" OR "payment successful") newer_than:{days}d'


class GmailMessageRef(BaseModel):
    id: str
    thread_id: str | None = None


class GmailMessage(BaseModel):
    id: str
    received_at: datetime
    sender: str
    subject: str
    text: str  # plain-text body


@runtime_checkable
class GmailClient(Protocol):
    """Provided at integration by the communications package as service ``gmail_client``."""

    async def search(self, query: str, *, max_results: int = 50) -> list[GmailMessageRef]: ...

    async def get(self, message_id: str) -> GmailMessage: ...


class Receipt(BaseModel):
    message_id: str
    merchant: str
    amount_paise: int
    day: date
    order_id: str | None = None


class ReceiptSyncResult(BaseModel):
    messages: int
    receipts: int
    matched: int
    skipped_existing: int


_AMOUNT_NEAR = re.compile(
    r"(?i)(order total|grand total|total amount|amount paid|total paid|total|amount)\s*[:\-]?\s*"
    r"((?:₹|rs\.?|inr)\s*[\d,]+(?:\.\d{1,2})?)"
)
_ANY_AMOUNT = re.compile(r"(?i)(?:₹|rs\.?|inr)\s*[\d,]+(?:\.\d{1,2})?")
_ORDER = re.compile(r"(?i)order\s*(?:id|no\.?|number|#)\s*[:#]?\s*([A-Z0-9\-]{5,40})")
_SENDER = re.compile(r"@([a-z0-9\-]+)\.", re.I)
_GENERIC_SENDERS = {"gmail", "mail", "email", "noreply", "info", "alerts", "notifications"}


def parse_receipt(message: GmailMessage, timezone: str = "Asia/Kolkata") -> Receipt | None:
    match = _AMOUNT_NEAR.search(message.text) or _AMOUNT_NEAR.search(message.subject)
    raw = match.group(2) if match else None
    if raw is None:
        any_amount = _ANY_AMOUNT.search(message.text)
        raw = any_amount.group(0) if any_amount else None
    try:
        amount = parse_amount(raw) if raw else None
    except AmountError:
        amount = None
    if amount is None or amount.value <= 0:
        return None
    domain = _SENDER.search(message.sender)
    name = (
        domain.group(1)
        if domain and domain.group(1).lower() not in _GENERIC_SENDERS
        else message.subject[:40]
    )
    order = _ORDER.search(message.text)
    return Receipt(
        message_id=message.id, merchant=name, amount_paise=to_paise(amount.value),
        day=message.received_at.astimezone(ZoneInfo(timezone)).date(), order_id=order.group(1) if order else None,
    )  # fmt: skip


class GmailReceiptConnector:
    """Registered as service ``finance_gmail``. The client is looked up lazily, so a communications
    package that loads later still wires in."""

    def __init__(
        self, client: Callable[[], GmailClient | None], session_factory: SessionFactory,
        categories: CategoryConfigSource, clock: Clock,
    ) -> None:  # fmt: skip
        self._client = client
        self._sf = session_factory
        self._categories = categories
        self._clock = clock

    def capability(self) -> Capability:
        wired = self._client() is not None
        return Capability(
            id="finance.gmail_receipts", title="Receipts from Gmail", domain="finance",
            status=CapabilityStatus.WORKING_INTEGRATION if wired else CapabilityStatus.REQUIRES_CREDENTIALS,
            integration_level=IntegrationLevel.OFFICIAL_API, requires=[] if wired else ["GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"],
            note=("Reads receipt emails through the Gmail API to name merchants on bank debits; receipts never count in totals."
                  if wired else "Connect Google in Integrations. gmail.readonly is a restricted scope: a personal app in "
                  "Testing mode must re-authorise every 7 days."),
        )  # fmt: skip

    async def sync(self, *, days: int = 30, max_results: int = 50) -> ReceiptSyncResult:
        client = self._client()
        if client is None:
            raise Unavailable("Gmail is not connected.", code="requires_credentials")
        refs = await client.search(RECEIPT_QUERY.format(days=days), max_results=max_results)
        config = self._categories.current()
        result = ReceiptSyncResult(messages=len(refs), receipts=0, matched=0, skipped_existing=0)
        async with self._sf() as session:
            account = await session.scalar(
                select(FinanceAccount).where(FinanceAccount.name == "Email receipts")
            )
            if account is None:
                account = FinanceAccount(id=new_id("facc"), name="Email receipts", kind="receipts",
                                         institution="gmail", created_at=self._clock.now())  # fmt: skip
                session.add(account)
                await session.flush()
            for ref in refs:
                print_ = hashlib.sha256(f"gmail|{ref.id}".encode()).hexdigest()
                if await session.scalar(select(T.id).where(T.fingerprint == print_)) is not None:
                    result.skipped_existing += 1
                    continue
                receipt = parse_receipt(await client.get(ref.id))
                if receipt is None:
                    continue
                norm = normalise(f"UPI/{receipt.merchant}", config.merchants)
                bank = await session.scalar(
                    select(T).where(
                        T.duplicate_of.is_(None), T.source_kind != "receipts", T.direction == "debit",
                        T.amount_paise == receipt.amount_paise,
                        T.txn_date >= receipt.day - timedelta(days=3), T.txn_date <= receipt.day + timedelta(days=3),
                    ).order_by(T.txn_date).limit(1)
                )  # fmt: skip
                session.add(T(
                    id=new_id("ftxn"), account_id=account.id, import_id=None, txn_date=receipt.day, value_date=None,
                    txn_month=receipt.day.strftime("%Y-%m"), narration=f"Email receipt {receipt.order_id or ''}".strip(),
                    counterparty=norm.merchant, merchant_key=norm.merchant_key, vpa=None, upi_ref=None, channel="other",
                    direction="debit", amount_paise=receipt.amount_paise, balance_paise=None,
                    category="uncategorised", category_source="default", confidence=0, source_kind="receipts",
                    source_file=f"gmail:{ref.id}", source_line=0, fingerprint=print_,
                    duplicate_of=bank.id if bank else None, duplicate_reason="receipt" if bank else None,
                    created_at=self._clock.now(),
                ))  # fmt: skip
                result.receipts += 1
                if bank is not None:
                    result.matched += 1
                    if is_weak(bank.merchant_key) and bank.category_source != "override":
                        bank.counterparty, bank.merchant_key = norm.merchant, merchant_key(norm.merchant)
            await session.commit()
        return result


class AccountAggregatorClient(Protocol):
    """RBI Account Aggregator, FIU side. Only an RBI / SEBI / IRDAI / PFRDA regulated entity may be a
    Financial Information User; an individual appears only as the consenting customer."""

    async def request_consent(self, customer_vua: str, fi_types: list[str], days: int) -> str: ...

    async def fetch(self, consent_id: str) -> list[dict[str, str]]: ...


class UnavailableAccountAggregator:
    reason = (
        "Account Aggregator data can only be received by a regulated FIU (RBI, SEBI, IRDAI, PFRDA). "
        "ZORO is a personal app, so import statements exported from your bank or UPI app instead."
    )

    async def request_consent(self, customer_vua: str, fi_types: list[str], days: int) -> str:
        raise Unavailable(self.reason, code="requires_partnership")

    async def fetch(self, consent_id: str) -> list[dict[str, str]]:
        raise Unavailable(self.reason, code="requires_partnership")


def static_capabilities() -> list[Capability]:
    return [
        Capability(id="finance.statement_import", title="Import bank and UPI statements (CSV, XLSX, PDF)",
                   domain="finance", status=CapabilityStatus.WORKING_LOCAL, integration_level=IntegrationLevel.MANUAL_FALLBACK,
                   requires=["user exports the statement"],
                   note="Parsed on your server. Profiles: HDFC, SBI, ICICI, Axis, Kotak, Paytm, BHIM, PhonePe, plus a generic layout."),
        Capability(id="finance.scanned_statement_ocr", title="Scanned statements", domain="finance",
                   status=CapabilityStatus.MANUAL_USER_STEP, integration_level=IntegrationLevel.MANUAL_FALLBACK,
                   requires=["text recognition on the iPhone or Mac"],
                   note="The server has no OCR engine. Scan on your device; the recognised text is sent to /v1/finance/imports/ocr."),
        Capability(id="finance.account_aggregator", title="Account Aggregator (RBI AA)", domain="finance",
                   status=CapabilityStatus.REQUIRES_PARTNERSHIP, integration_level=IntegrationLevel.UNAVAILABLE,
                   requires=["regulated FIU status (RBI, SEBI, IRDAI or PFRDA)", "Sahamati certification"],
                   note=UnavailableAccountAggregator.reason),
    ]  # fmt: skip
