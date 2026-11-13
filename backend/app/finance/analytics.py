"""Spending analytics in SQL over integer paise, converted to Decimal rupees only at the edge.

Counted rows: not a duplicate (`duplicate_of IS NULL`) and not an email receipt (receipts only
enrich bank rows). Every total here is the exact sum of the rows it describes.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import ROUND_HALF_EVEN, Decimal
from typing import Any

from sqlalchemy import ColumnElement, and_, func, or_, select

from app.core.money import from_paise
from app.db.session import SessionFactory
from app.finance.categories import CategoryConfigSource
from app.finance.models import FinanceTransaction as T
from app.finance.normalise import merchant_key
from app.finance.periods import Period, month_keys
from app.finance.schemas import (
    CategoryBreakdown,
    CategoryTotal,
    IncomeExpense,
    MerchantReport,
    MerchantTotal,
    MonthRow,
    SpendingSummary,
    TransactionList,
    TransactionOut,
)

PAGE_MAX = 200


def counted() -> ColumnElement[bool]:
    return and_(T.duplicate_of.is_(None), T.source_kind != "receipts")


def in_period(period: Period) -> ColumnElement[bool]:
    return and_(T.txn_date >= period.start, T.txn_date <= period.end)


def pct(part: int, whole: int) -> Decimal:
    if whole == 0:
        return Decimal("0.0")
    return (Decimal(part) * 100 / Decimal(whole)).quantize(Decimal("0.1"), rounding=ROUND_HALF_EVEN)


def to_out(t: T) -> TransactionOut:
    return TransactionOut(
        id=t.id, account_id=t.account_id, date=t.txn_date, value_date=t.value_date, narration=t.narration,
        counterparty=t.counterparty, vpa=t.vpa, upi_ref=t.upi_ref, channel=t.channel,
        direction="debit" if t.direction == "debit" else "credit", amount=from_paise(t.amount_paise),
        balance=from_paise(t.balance_paise) if t.balance_paise is not None else None, category=t.category,
        category_source=t.category_source, confidence=t.confidence, source_file=t.source_file,
        duplicate_of=t.duplicate_of,
    )  # fmt: skip


@dataclass(frozen=True)
class SearchFilters:
    query: str | None = None
    category: str | None = None
    merchant: str | None = None
    direction: str | None = None
    channel: str | None = None
    account_id: str | None = None
    min_paise: int | None = None
    max_paise: int | None = None
    include_duplicates: bool = False


class FinanceAnalytics:
    """Registered as service ``finance_analytics``."""

    def __init__(self, session_factory: SessionFactory, categories: CategoryConfigSource) -> None:
        self._sf = session_factory
        self._categories = categories

    def resolve_merchant(self, name: str) -> str:
        key = merchant_key(name)
        aliases = self._categories.current().merchants
        return merchant_key(aliases[key]) if key in aliases else key

    async def _rows(self, stmt: Any) -> Sequence[Any]:
        async with self._sf() as session:
            return (await session.execute(stmt)).all()

    async def totals(self, period: Period, *, category: str | None = None) -> dict[str, tuple[int, int]]:
        """direction -> (paise, count)."""
        where = [counted(), in_period(period)] + ([T.category == category] if category else [])
        stmt = select(T.direction, func.coalesce(func.sum(T.amount_paise), 0), func.count()).where(*where)
        rows = await self._rows(stmt.group_by(T.direction))
        return {str(d): (int(s), int(c)) for d, s, c in rows}

    async def by_category(self, period: Period, direction: str = "debit") -> list[tuple[str, int, int]]:
        stmt = (
            select(T.category, func.sum(T.amount_paise), func.count())
            .where(counted(), in_period(period), T.direction == direction)
            .group_by(T.category)
        )
        rows = [(str(c), int(s), int(n)) for c, s, n in await self._rows(stmt)]
        return sorted(rows, key=lambda r: (-r[1], r[0]))

    def _category_totals(self, rows: list[tuple[str, int, int]], total: int) -> list[CategoryTotal]:
        config = self._categories.current()
        return [
            CategoryTotal(
                category=c, name=config.name(c), amount=from_paise(s), count=n, share_pct=pct(s, total)
            )
            for c, s, n in rows
        ]

    async def spending_summary(self, period: Period, category: str | None = None) -> SpendingSummary:
        totals = await self.totals(period, category=category)
        spent, n_debit = totals.get("debit", (0, 0))
        received, n_credit = totals.get("credit", (0, 0))
        top = [] if category else self._category_totals((await self.by_category(period))[:3], spent)
        return SpendingSummary(
            period=period, category=category,
            category_name=self._categories.current().name(category) if category else None,
            spent=from_paise(spent), received=from_paise(received), net=from_paise(received - spent),
            transactions=n_debit + n_credit, top_categories=top,
        )  # fmt: skip

    async def category_breakdown(self, period: Period, direction: str = "debit") -> CategoryBreakdown:
        rows = await self.by_category(period, direction)
        total = sum(s for _, s, _ in rows)
        return CategoryBreakdown(
            period=period, direction="credit" if direction == "credit" else "debit", total=from_paise(total),
            transactions=sum(n for _, _, n in rows), categories=self._category_totals(rows, total),
        )  # fmt: skip

    async def income_expense(self, period: Period) -> IncomeExpense:
        stmt = (
            select(T.txn_month, T.direction, func.sum(T.amount_paise))
            .where(counted(), in_period(period))
            .group_by(T.txn_month, T.direction)
        )
        cells = {(str(m), str(d)): int(s) for m, d, s in await self._rows(stmt)}
        months = [
            MonthRow(
                month=m, income=from_paise(cells.get((m, "credit"), 0)), expense=from_paise(cells.get((m, "debit"), 0)),
                net=from_paise(cells.get((m, "credit"), 0) - cells.get((m, "debit"), 0)),
            )
            for m in month_keys(period)
        ]  # fmt: skip
        income = sum(v for (_, d), v in cells.items() if d == "credit")
        expense = sum(v for (_, d), v in cells.items() if d == "debit")
        return IncomeExpense(
            period=period, income=from_paise(income), expense=from_paise(expense), net=from_paise(income - expense),
            savings_rate_pct=pct(income - expense, income) if income else None, months=months,
        )  # fmt: skip

    async def merchants(
        self, period: Period, direction: str = "debit", limit: int = 10
    ) -> list[MerchantTotal]:
        stmt = (
            select(T.merchant_key, func.max(T.counterparty), func.sum(T.amount_paise), func.count())
            .where(counted(), in_period(period), T.direction == direction)
            .group_by(T.merchant_key)
        )
        rows = sorted(((str(k), str(n), int(s), int(c)) for k, n, s, c in await self._rows(stmt)),
                      key=lambda r: (-r[2], r[0]))  # fmt: skip
        return [
            MerchantTotal(merchant=n, merchant_key=k, amount=from_paise(s), count=c)
            for k, n, s, c in rows[:limit]
        ]

    async def merchant_report(self, period: Period, merchant: str | None = None) -> MerchantReport:
        if merchant is None:
            top = await self.merchants(period)
            listed = sum((m.amount for m in top), Decimal("0.00"))
            return MerchantReport(period=period, total=listed, count=sum(m.count for m in top), merchants=top)
        key = self.resolve_merchant(merchant)
        match = or_(T.merchant_key == key, T.merchant_key.like(key + " %"))
        stmt = select(
            func.coalesce(func.sum(T.amount_paise), 0), func.count(), func.min(T.txn_date), func.max(T.txn_date),
            func.max(T.counterparty),
        ).where(counted(), in_period(period), T.direction == "debit", match)  # fmt: skip
        raw_total, raw_count, first, last, name = (await self._rows(stmt))[0]
        total, count = int(raw_total), int(raw_count)
        average = (
            (Decimal(total) / count / 100).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
            if count
            else None
        )
        return MerchantReport(
            period=period, merchant=str(name) if name else merchant, total=from_paise(total), count=count,
            average=average, first_date=first, last_date=last,
        )  # fmt: skip

    async def search(
        self, period: Period, filters: SearchFilters, *, limit: int = 20, offset: int = 0
    ) -> TransactionList:
        where: list[ColumnElement[bool]] = [in_period(period)]
        if not filters.include_duplicates:
            where.append(counted())
        if filters.category:
            where.append(T.category == filters.category)
        if filters.direction:
            where.append(T.direction == filters.direction)
        if filters.channel:
            where.append(T.channel == filters.channel)
        if filters.account_id:
            where.append(T.account_id == filters.account_id)
        if filters.merchant:
            key = self.resolve_merchant(filters.merchant)
            where.append(or_(T.merchant_key == key, T.merchant_key.like(key + " %")))
        if filters.query:
            like = f"%{filters.query.lower()}%"
            where.append(or_(func.lower(T.narration).like(like), T.merchant_key.like(like)))
        if filters.min_paise is not None:
            where.append(T.amount_paise >= filters.min_paise)
        if filters.max_paise is not None:
            where.append(T.amount_paise <= filters.max_paise)
        limit = max(1, min(limit, PAGE_MAX))
        agg = select(T.direction, func.coalesce(func.sum(T.amount_paise), 0), func.count()).where(*where)
        sums = {str(d): (int(s), int(c)) for d, s, c in await self._rows(agg.group_by(T.direction))}
        async with self._sf() as session:
            rows = (
                await session.scalars(
                    select(T).where(*where).order_by(T.txn_date.desc(), T.source_line.desc(), T.id)
                    .offset(offset).limit(limit + 1)
                )
            ).all()  # fmt: skip
        count = sum(c for _, c in sums.values())
        return TransactionList(
            period=period, total_debit=from_paise(sums.get("debit", (0, 0))[0]),
            total_credit=from_paise(sums.get("credit", (0, 0))[0]), count=count,
            items=[to_out(t) for t in rows[:limit]],
            next_cursor=str(offset + limit) if len(rows) > limit else None,
        )  # fmt: skip
