"""Statement import: read -> parse -> normalise -> categorise -> de-duplicate -> store.

- Idempotent: the sha256 of the bytes identifies an import; the same file twice returns the first
  result with `already_imported`.
- Read-only towards accounts: an import only writes ZORO's own tables.
- Duplicates: within a file (same UPI reference, or identical row and running balance) and across
  sources (same UPI reference / RRN and amount; or the same row from an overlapping statement).
- Reconciliation: a UPI app's copy of a bank row is marked as a duplicate of the bank row (never
  counted twice) and lends the bank row its cleaner payee name.
"""

from __future__ import annotations

import asyncio
import hashlib
import re
from collections.abc import Mapping
from dataclasses import dataclass, field

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import Clock
from app.core.money import to_paise
from app.db.base import new_id
from app.db.session import SessionFactory
from app.finance.categories import CategoryConfig, CategoryConfigSource
from app.finance.mapping import ParsedRow, ParsedStatement, check_balances, parse_rows
from app.finance.models import FinanceAccount, FinanceCategoryRule, FinanceImport, FinanceTransaction
from app.finance.normalise import Normalised, mask_vpa, merchant_key, normalise
from app.finance.readers import RawTable, StatementReadError, read_statement, read_text
from app.finance.schemas import AccountOut, ImportStatus, RowIssue

_WEAK = ("unknown", "upi payee")
_APP_PREFIX = re.compile(r"(?i)^(paid to|payment to|money sent to|sent to|received from|money received from|"
                         r"transfer to|transfer from|paid for|refund from)\s+")  # fmt: skip
_RANK = {"bank": 0, "upi_app": 1, "receipts": 2}
_PROFILE_NAMES = {
    "hdfc_bank": "HDFC Bank", "sbi": "SBI", "icici_bank": "ICICI Bank", "axis_bank": "Axis Bank",
    "kotak_bank": "Kotak Bank", "paytm_passbook": "Paytm", "bhim_upi": "BHIM", "phonepe": "PhonePe",
    "generic": "Bank statement",
}  # fmt: skip


def file_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fingerprint(account_id: str, row: ParsedRow, key: str) -> str:
    parts = [account_id, row.txn_date.isoformat(), row.direction, str(to_paise(row.amount)), key]
    return hashlib.sha256("|".join(parts).encode()).hexdigest()


def is_weak(key: str) -> bool:
    return key.startswith(_WEAK)


def _upi_app_normalise(row: ParsedRow, config: CategoryConfig) -> Normalised:
    """UPI app exports say "Paid to Swiggy" with the VPA in its own column."""
    base = normalise(row.narration, config.merchants)
    vpa = mask_vpa(row.counterparty) if row.counterparty and "@" in row.counterparty else base.vpa
    name = _APP_PREFIX.sub("", row.narration).strip()
    if not name and row.counterparty and "@" not in row.counterparty:
        name = row.counterparty
    if name and not is_weak(merchant_key(name)):
        named = normalise(f"UPI/{name}", config.merchants)
        return Normalised(named.merchant, named.merchant_key, "upi", vpa, row.ref or base.upi_ref)
    return Normalised(base.merchant, base.merchant_key, "upi", vpa, row.ref or base.upi_ref)


@dataclass
class _Counts:
    imported: int = 0
    duplicate: int = 0
    reconciled: int = 0
    issues: list[RowIssue] = field(default_factory=list)


class ImportService:
    """Registered as service ``finance_imports``."""

    def __init__(
        self, session_factory: SessionFactory, categories: CategoryConfigSource, clock: Clock
    ) -> None:
        self._sf = session_factory
        self._categories = categories
        self._clock = clock

    async def import_file(
        self, filename: str, data: bytes, *, account_name: str | None = None
    ) -> ImportStatus:
        digest = file_hash(data)
        existing = await self._existing(digest)
        if existing is not None:
            return existing
        try:
            table = await asyncio.to_thread(read_statement, filename, data)
        except StatementReadError as exc:
            return await self._failed(digest, filename, "unknown", str(exc))
        return await self._import_table(digest, filename, table, account_name)

    async def import_ocr_text(
        self, text: str, filename: str, *, account_name: str | None = None
    ) -> ImportStatus:
        digest = file_hash(b"ocr\x00" + text.encode("utf-8"))
        existing = await self._existing(digest)
        if existing is not None:
            return existing
        return await self._import_table(digest, filename, read_text(text), account_name)

    async def status(self, import_id: str) -> ImportStatus | None:
        async with self._sf() as session:
            row = await session.get(FinanceImport, import_id)
            return None if row is None else await self._to_status(session, row)

    async def recent(self, limit: int = 50) -> list[ImportStatus]:
        async with self._sf() as session:
            rows = (
                await session.scalars(
                    select(FinanceImport).order_by(FinanceImport.created_at.desc()).limit(limit)
                )
            ).all()
            return [await self._to_status(session, r) for r in rows]

    async def accounts(self) -> list[AccountOut]:
        T = FinanceTransaction
        async with self._sf() as session:
            accounts = (await session.scalars(select(FinanceAccount).order_by(FinanceAccount.name))).all()
            stats = {
                str(a): (int(n), lo, hi)
                for a, n, lo, hi in (
                    await session.execute(
                        select(T.account_id, func.count(), func.min(T.txn_date), func.max(T.txn_date))
                        .where(T.duplicate_of.is_(None))
                        .group_by(T.account_id)
                    )
                ).all()
            }
        return [
            AccountOut(id=a.id, name=a.name, kind=a.kind, institution=a.institution,
                       transactions=stats.get(a.id, (0, None, None))[0], first_date=stats.get(a.id, (0, None, None))[1],
                       last_date=stats.get(a.id, (0, None, None))[2])
            for a in accounts
        ]  # fmt: skip

    # ------------------------------------------------------------ internals

    async def _existing(self, digest: str) -> ImportStatus | None:
        async with self._sf() as session:
            row = await session.scalar(select(FinanceImport).where(FinanceImport.file_hash == digest))
            if row is None:
                return None
            if row.status == "failed":  # a failed read may succeed now (e.g. a fixed parser): retry
                await session.delete(row)
                await session.commit()
                return None
            status = await self._to_status(session, row)
        return status.model_copy(update={"already_imported": True})

    async def _failed(self, digest: str, filename: str, kind: str, message: str) -> ImportStatus:
        async with self._sf() as session:
            row = FinanceImport(
                id=new_id("fimp"), file_hash=digest, filename=filename[:255], file_kind=kind, source_kind="bank",
                profile="unknown", status="failed", message=message, errors=[], created_at=self._clock.now(),
            )  # fmt: skip
            session.add(row)
            await session.commit()
            return await self._to_status(session, row)

    async def _account(self, session: AsyncSession, name: str, kind: str, profile: str) -> FinanceAccount:
        account = await session.scalar(select(FinanceAccount).where(FinanceAccount.name == name))
        if account is None:
            account = FinanceAccount(
                id=new_id("facc"), name=name, kind=kind, institution=profile, created_at=self._clock.now()
            )
            session.add(account)
            await session.flush()
        return account

    async def _import_table(
        self, digest: str, filename: str, table: RawTable, account_name: str | None
    ) -> ImportStatus:
        stmt = parse_rows(table.rows, text_rows=table.text_rows)
        if stmt.header is None:
            return await self._failed(
                digest, filename, table.kind, "no statement header found (date, amount, description)"
            )
        if not stmt.rows:
            message = "no transactions could be read"
            return await self._failed(digest, filename, table.kind, message)
        config = self._categories.current()
        header = stmt.header
        name = (account_name or _PROFILE_NAMES.get(header.profile, header.profile)).strip()[:120]
        async with self._sf() as session:
            account = await self._account(session, name, header.source_kind, header.profile)
            overrides = await load_overrides(session)
            imp = FinanceImport(
                id=new_id("fimp"), file_hash=digest, filename=filename[:255], file_kind=table.kind,
                source_kind=header.source_kind, profile=header.profile, account_id=account.id, status="completed",
                created_at=self._clock.now(),
                period_start=min(r.txn_date for r in stmt.rows), period_end=max(r.txn_date for r in stmt.rows),
            )  # fmt: skip
            session.add(imp)
            await session.flush()
            counts = await self._store_rows(session, stmt, imp, account, config, overrides)
            check = check_balances(stmt)
            errors = [RowIssue(line=e.line, reason=e.reason) for e in stmt.errors]
            imp.rows_total = len(stmt.rows) + len(stmt.errors) + len(stmt.skipped)
            imp.rows_imported, imp.rows_duplicate, imp.rows_reconciled = (
                counts.imported,
                counts.duplicate,
                counts.reconciled,
            )
            imp.rows_skipped, imp.rows_error = len(stmt.skipped), len(stmt.errors)
            imp.balance_check = check.status
            imp.status = "partial" if errors or check.status == "mismatch" else "completed"
            imp.message = check.detail
            imp.errors = [e.model_dump() for e in errors[:100]]
            await session.commit()
            return await self._to_status(session, imp)

    async def _store_rows(
        self,
        session: AsyncSession,
        stmt: ParsedStatement,
        imp: FinanceImport,
        account: FinanceAccount,
        config: CategoryConfig,
        overrides: Mapping[str, str],
    ) -> _Counts:
        counts = _Counts()
        seen_refs: dict[tuple[str, str, int], FinanceTransaction] = {}
        seen_prints: dict[tuple[str, int | None], FinanceTransaction] = {}
        for row in stmt.rows:
            norm = (
                _upi_app_normalise(row, config)
                if imp.source_kind == "upi_app"
                else normalise(row.narration, config.merchants)
            )
            ref = (row.ref or norm.upi_ref or None) and str(row.ref or norm.upi_ref)[:40]
            paise = to_paise(row.amount)
            balance = to_paise(row.balance) if row.balance is not None else None
            cat = config.categorise(norm, row.narration, row.direction, overrides)
            txn = FinanceTransaction(
                id=new_id("ftxn"), account_id=account.id, import_id=imp.id, txn_date=row.txn_date,
                value_date=row.value_date, txn_month=row.txn_date.strftime("%Y-%m"), narration=row.narration[:2000],
                counterparty=norm.merchant[:160], merchant_key=norm.merchant_key[:160], vpa=norm.vpa, upi_ref=ref,
                channel=norm.channel, direction=row.direction, amount_paise=paise, balance_paise=balance,
                category=cat.category, category_source=cat.source, confidence=cat.confidence,
                source_kind=imp.source_kind, source_file=imp.filename, source_line=row.line,
                fingerprint=fingerprint(account.id, row, norm.merchant_key), created_at=self._clock.now(),
            )  # fmt: skip
            # within this file
            first = seen_refs.get((ref, row.direction, paise)) if ref else None
            if first is None:
                first = seen_prints.get((txn.fingerprint, balance)) if balance is not None or ref else None
            if first is not None:
                txn.duplicate_of, txn.duplicate_reason = first.id, "same_file"
            else:
                await self._cross_source(session, txn, config, overrides, counts)
            if txn.duplicate_of is None:
                if ref:
                    seen_refs[(ref, row.direction, paise)] = txn
                seen_prints[(txn.fingerprint, balance)] = txn
                counts.imported += 1
            else:
                counts.duplicate += int(txn.duplicate_reason != "reconciled_upi")
            session.add(txn)
        return counts

    async def _cross_source(
        self,
        session: AsyncSession,
        txn: FinanceTransaction,
        config: CategoryConfig,
        overrides: Mapping[str, str],
        counts: _Counts,
    ) -> None:
        live = FinanceTransaction.duplicate_of.is_(None)
        if txn.upi_ref:
            other = await session.scalar(
                select(FinanceTransaction).where(
                    live, FinanceTransaction.upi_ref == txn.upi_ref,
                    FinanceTransaction.amount_paise == txn.amount_paise,
                    FinanceTransaction.direction == txn.direction,
                ).limit(1)
            )  # fmt: skip
            if other is not None:
                if other.source_kind == txn.source_kind:
                    txn.duplicate_of, txn.duplicate_reason = other.id, "overlap"
                    return
                keep, drop = (
                    (other, txn) if _RANK[other.source_kind] <= _RANK[txn.source_kind] else (txn, other)
                )
                drop.duplicate_of, drop.duplicate_reason = keep.id, "reconciled_upi"
                if is_weak(keep.merchant_key) and not is_weak(drop.merchant_key):
                    keep.counterparty, keep.merchant_key = drop.counterparty, drop.merchant_key
                    keep.vpa = keep.vpa or drop.vpa
                    if keep.category_source != "override":
                        norm = Normalised(keep.counterparty, keep.merchant_key, "upi", keep.vpa, keep.upi_ref)
                        cat = config.categorise(
                            norm,
                            keep.narration,
                            "debit" if keep.direction == "debit" else "credit",
                            overrides,
                        )
                        keep.category, keep.category_source, keep.confidence = (
                            cat.category,
                            cat.source,
                            cat.confidence,
                        )
                counts.reconciled += 1
                return
        other = await session.scalar(
            select(FinanceTransaction).where(
                live, FinanceTransaction.fingerprint == txn.fingerprint,
                FinanceTransaction.import_id != txn.import_id,
            ).limit(1)
        )  # fmt: skip
        if other is not None and (
            other.balance_paise is None
            or txn.balance_paise is None
            or other.balance_paise == txn.balance_paise
        ):
            txn.duplicate_of, txn.duplicate_reason = other.id, "overlap"

    async def _to_status(self, session: AsyncSession, row: FinanceImport) -> ImportStatus:
        account = await session.get(FinanceAccount, row.account_id) if row.account_id else None
        return ImportStatus(
            id=row.id, filename=row.filename, file_kind=row.file_kind, source_kind=row.source_kind,
            profile=row.profile, account_id=row.account_id, account_name=account.name if account else None,
            status=row.status, rows_total=row.rows_total, rows_imported=row.rows_imported,
            rows_duplicate=row.rows_duplicate, rows_reconciled=row.rows_reconciled, rows_skipped=row.rows_skipped,
            rows_error=row.rows_error, balance_check=row.balance_check,
            message=row.message, errors=[RowIssue.model_validate(e) for e in row.errors or []],
            period_start=row.period_start, period_end=row.period_end, created_at=row.created_at,
        )  # fmt: skip


async def load_overrides(session: AsyncSession) -> dict[str, str]:
    rows = (await session.scalars(select(FinanceCategoryRule))).all()
    return {r.merchant_key: r.category for r in rows}
