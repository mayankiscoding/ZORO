"""Finance tables. Money is integer paise (`BigInteger`); dates are calendar dates (owner's timezone)."""

from __future__ import annotations

from datetime import date, datetime
from typing import Any

from sqlalchemy import BigInteger, Date, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime, utcnow
from app.db.types import JSONType


class FinanceAccount(Base):
    """A local label for where transactions came from. Nothing here can act on a real account."""

    __tablename__ = "finance_accounts"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True)
    kind: Mapped[str] = mapped_column(String(16))  # bank | upi_app | receipts
    institution: Mapped[str | None] = mapped_column(String(64), nullable=True)  # profile, e.g. hdfc_bank
    currency: Mapped[str] = mapped_column(String(3), default="INR")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class FinanceImport(Base):
    __tablename__ = "finance_imports"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    file_hash: Mapped[str] = mapped_column(String(64), unique=True)  # sha256 of the bytes: idempotency
    filename: Mapped[str] = mapped_column(String(255))
    file_kind: Mapped[str] = mapped_column(String(16))  # csv | xlsx | pdf | ocr_text | gmail
    source_kind: Mapped[str] = mapped_column(String(16))  # bank | upi_app | receipts
    profile: Mapped[str] = mapped_column(String(32))
    account_id: Mapped[str | None] = mapped_column(ForeignKey("finance_accounts.id"), nullable=True)
    status: Mapped[str] = mapped_column(String(16))  # completed | partial | failed
    rows_total: Mapped[int] = mapped_column(Integer, default=0)
    rows_imported: Mapped[int] = mapped_column(Integer, default=0)
    rows_duplicate: Mapped[int] = mapped_column(Integer, default=0)
    rows_reconciled: Mapped[int] = mapped_column(Integer, default=0)
    rows_skipped: Mapped[int] = mapped_column(Integer, default=0)
    rows_error: Mapped[int] = mapped_column(Integer, default=0)
    balance_check: Mapped[str] = mapped_column(String(16), default="not_available")
    message: Mapped[str] = mapped_column(Text, default="")
    errors: Mapped[list[dict[str, Any]]] = mapped_column(JSONType, default=list)  # row numbers + reasons
    period_start: Mapped[date | None] = mapped_column(Date, nullable=True)
    period_end: Mapped[date | None] = mapped_column(Date, nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class FinanceTransaction(Base):
    __tablename__ = "finance_transactions"
    __table_args__ = (
        Index("ix_finance_txn_account_date", "account_id", "txn_date"),
        Index("ix_finance_txn_month", "txn_month"),
    )

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("finance_accounts.id"), index=True)
    import_id: Mapped[str | None] = mapped_column(ForeignKey("finance_imports.id"), nullable=True, index=True)
    txn_date: Mapped[date] = mapped_column(Date)
    value_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    txn_month: Mapped[str] = mapped_column(String(7))  # "YYYY-MM", for portable SQL grouping
    narration: Mapped[str] = mapped_column(Text)
    counterparty: Mapped[str] = mapped_column(String(160))  # normalised merchant / payee display name
    merchant_key: Mapped[str] = mapped_column(String(160), index=True)
    vpa: Mapped[str | None] = mapped_column(String(255), nullable=True)
    upi_ref: Mapped[str | None] = mapped_column(String(40), nullable=True, index=True)  # UPI ref / RRN / UTR
    channel: Mapped[str] = mapped_column(String(8))  # upi | card | neft | imps | atm | cash | other
    direction: Mapped[str] = mapped_column(String(6))  # debit | credit
    amount_paise: Mapped[int] = mapped_column(BigInteger)  # always > 0
    balance_paise: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    currency: Mapped[str] = mapped_column(String(3), default="INR")
    category: Mapped[str] = mapped_column(String(40), index=True)
    category_source: Mapped[str] = mapped_column(String(10))  # override | rule | model | default
    confidence: Mapped[int] = mapped_column(Integer)  # 0..100
    source_kind: Mapped[str] = mapped_column(String(16))  # bank | upi_app | receipts
    source_file: Mapped[str] = mapped_column(String(255))
    source_line: Mapped[int] = mapped_column(Integer, default=0)
    fingerprint: Mapped[str] = mapped_column(String(64), index=True)
    # Set when this row repeats another one (same statement twice, or the UPI app's copy of a bank
    # row). Such rows never count in totals.
    duplicate_of: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    duplicate_reason: Mapped[str | None] = mapped_column(String(32), nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class FinanceCategoryRule(Base):
    """Owner override: every transaction with this merchant key gets this category."""

    __tablename__ = "finance_category_rules"

    merchant_key: Mapped[str] = mapped_column(String(160), primary_key=True)
    category: Mapped[str] = mapped_column(String(40))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class FinanceBudget(Base):
    __tablename__ = "finance_budgets"
    __table_args__ = (UniqueConstraint("category", "period", name="uq_finance_budgets_category_period"),)

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    category: Mapped[str] = mapped_column(String(40))  # a category id, or "all"
    period: Mapped[str] = mapped_column(String(8), default="monthly")
    limit_paise: Mapped[int] = mapped_column(BigInteger)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
