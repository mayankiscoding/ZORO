"""Finance DTOs (API bodies and tool inputs / outputs). Money is `Decimal` rupees with two places,
serialised as a decimal string; it is always computed from integer paise."""

from __future__ import annotations

import datetime as _dt
from datetime import date, datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.finance.periods import Period

Direction = Literal["debit", "credit"]
ChannelName = Literal["upi", "card", "neft", "imps", "atm", "cash", "other"]


class FModel(BaseModel):
    model_config = ConfigDict(extra="ignore")


# ---------------------------------------------------------------- imports and records


class RowIssue(FModel):
    line: int
    reason: str


class ImportStatus(FModel):
    id: str
    filename: str
    file_kind: str
    source_kind: str
    profile: str
    account_id: str | None
    account_name: str | None
    status: Literal["completed", "partial", "failed"]
    rows_total: int
    rows_imported: int
    rows_duplicate: int
    rows_reconciled: int
    rows_skipped: int
    rows_error: int
    balance_check: Literal["ok", "mismatch", "not_available"]
    message: str = ""
    errors: list[RowIssue] = Field(default_factory=list)
    period_start: date | None = None
    period_end: date | None = None
    created_at: datetime
    already_imported: bool = False


class OcrImportRequest(FModel):
    """Text recognised on the device from a scanned statement (the server has no OCR engine)."""

    text: str = Field(min_length=1, max_length=2_000_000)
    filename: str = Field(default="scanned-statement.txt", max_length=255)
    account_name: str | None = Field(default=None, max_length=120)


class AccountOut(FModel):
    id: str
    name: str
    kind: str
    institution: str | None
    transactions: int
    first_date: date | None
    last_date: date | None


class TransactionOut(FModel):
    id: str
    account_id: str
    date: _dt.date
    value_date: _dt.date | None
    narration: str
    counterparty: str
    vpa: str | None
    upi_ref: str | None
    channel: str
    direction: Direction
    amount: Decimal
    balance: Decimal | None
    category: str
    category_source: str
    confidence: int
    source_file: str
    duplicate_of: str | None = None


class CategoryOut(FModel):
    id: str
    name: str
    name_hi: str
    name_hinglish: str
    direction: str | None


class CategoryOverride(FModel):
    category: str = Field(min_length=1, max_length=40)
    apply_to_merchant: bool = False


class BudgetIn(FModel):
    limit: Decimal = Field(gt=0, max_digits=14, decimal_places=2)

    @field_validator("limit", mode="before")
    @classmethod
    def _no_float(cls, value: object) -> object:
        if isinstance(value, float):
            raise ValueError("send the amount as a decimal string")
        return value


# ---------------------------------------------------------------- analytics results


class CategoryTotal(FModel):
    category: str
    name: str
    amount: Decimal
    count: int
    share_pct: Decimal  # one decimal place


class MerchantTotal(FModel):
    merchant: str
    merchant_key: str
    amount: Decimal
    count: int


class MonthRow(FModel):
    month: str  # YYYY-MM
    income: Decimal
    expense: Decimal
    net: Decimal


class SpendingSummary(FModel):
    period: Period
    category: str | None = None
    category_name: str | None = None
    spent: Decimal
    received: Decimal
    net: Decimal
    transactions: int
    top_categories: list[CategoryTotal] = Field(default_factory=list)


class CategoryBreakdown(FModel):
    period: Period
    direction: Direction
    total: Decimal
    transactions: int
    categories: list[CategoryTotal]


class IncomeExpense(FModel):
    period: Period
    income: Decimal
    expense: Decimal
    net: Decimal
    savings_rate_pct: Decimal | None  # None when there is no income
    months: list[MonthRow]


class MerchantReport(FModel):
    period: Period
    merchant: str | None = None
    total: Decimal
    count: int
    average: Decimal | None = None
    first_date: date | None = None
    last_date: date | None = None
    merchants: list[MerchantTotal] = Field(default_factory=list)


class TransactionList(FModel):
    period: Period
    total_debit: Decimal
    total_credit: Decimal
    count: int  # matching rows (may exceed len(items))
    items: list[TransactionOut]
    next_cursor: str | None = None


class RecurringItem(FModel):
    merchant: str
    merchant_key: str
    category: str
    direction: Direction
    cadence: Literal["weekly", "monthly", "quarterly", "yearly"]
    typical_amount: Decimal  # median
    min_amount: Decimal
    max_amount: Decimal
    occurrences: int
    first_date: date
    last_date: date
    next_expected: date
    is_subscription: bool


class RecurringReport(FModel):
    as_of: date
    items: list[RecurringItem]
    monthly_total: Decimal  # debits, normalised to one month (weekly x 52 / 12, yearly / 12, ...)


class BudgetStatusItem(FModel):
    category: str
    name: str
    limit: Decimal
    spent: Decimal
    remaining: Decimal
    used_pct: Decimal  # one decimal place
    state: Literal["ok", "warning", "exceeded"]


class BudgetStatus(FModel):
    period: Period
    items: list[BudgetStatusItem]


class ForecastLine(FModel):
    label: str
    direction: Direction
    amount: Decimal
    basis: str  # recurring:<cadence> | trailing_average


class CashflowForecast(FModel):
    as_of: date
    horizon_days: int
    start: date
    end: date
    expected_outflow: Decimal
    outflow_low: Decimal
    outflow_high: Decimal
    expected_inflow: Decimal
    net: Decimal
    method: str
    lines: list[ForecastLine]


class Alert(FModel):
    kind: Literal["budget_exceeded", "unusual_spend", "new_subscription", "possible_duplicate_charge"]
    message: str
    category: str | None = None
    merchant: str | None = None
    amount: Decimal | None = None
    transaction_ids: list[str] = Field(default_factory=list)
    date: _dt.date | None = None


class AlertList(FModel):
    as_of: date
    alerts: list[Alert]
