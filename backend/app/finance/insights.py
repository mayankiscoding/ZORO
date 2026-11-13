"""Budgets, recurring payments, forecast and alerts (database side; maths in `recurring`)."""

from __future__ import annotations

from datetime import date, timedelta
from decimal import Decimal
from statistics import median_low

from sqlalchemy import select

from app.core.clock import Clock
from app.core.errors import NotFound, ValidationFailed
from app.core.money import from_paise, to_paise
from app.db.base import new_id
from app.db.session import SessionFactory
from app.finance.analytics import FinanceAnalytics, counted, pct
from app.finance.categories import CategoryConfigSource
from app.finance.importer import load_overrides
from app.finance.models import FinanceBudget, FinanceCategoryRule
from app.finance.models import FinanceTransaction as T
from app.finance.periods import Period
from app.finance.recurring import TxnPoint, detect_recurring, forecast
from app.finance.schemas import (
    Alert,
    AlertList,
    BudgetStatus,
    BudgetStatusItem,
    CashflowForecast,
    RecurringReport,
    TransactionOut,
)

LOOKBACK_DAYS = 400
WARNING_PCT = Decimal(80)
UNUSUAL_FACTOR = 3
UNUSUAL_MIN_PAISE = 100_000  # ₹1,000
UNUSUAL_MIN_SAMPLES = 5


class FinanceInsights:
    """Registered as service ``finance_insights``."""

    def __init__(
        self, session_factory: SessionFactory, categories: CategoryConfigSource, analytics: FinanceAnalytics,
        clock: Clock,
    ) -> None:  # fmt: skip
        self._sf = session_factory
        self._categories = categories
        self._analytics = analytics
        self._clock = clock

    async def points(self, as_of: date, days: int = LOOKBACK_DAYS) -> list[TxnPoint]:
        async with self._sf() as session:
            rows = (
                await session.scalars(
                    select(T).where(counted(), T.txn_date > as_of - timedelta(days=days), T.txn_date <= as_of)
                )
            ).all()
        return [TxnPoint(t.id, t.merchant_key, t.counterparty, t.category, t.direction, t.txn_date, t.amount_paise)
                for t in rows]  # fmt: skip

    async def recurring(self, as_of: date) -> RecurringReport:
        from app.finance.recurring import monthly_equivalent

        items = detect_recurring(await self.points(as_of), as_of)
        monthly = sum(monthly_equivalent(i) for i in items if i.direction == "debit")
        return RecurringReport(as_of=as_of, items=items, monthly_total=from_paise(monthly))

    async def forecast(self, as_of: date, horizon_days: int) -> CashflowForecast:
        points = await self.points(as_of)
        return forecast(detect_recurring(points, as_of), points, as_of, horizon_days)

    # ------------------------------------------------------------ budgets

    def _check_category(self, category: str) -> str:
        if category != "all" and self._categories.current().get(category) is None:
            raise ValidationFailed(f"unknown category: {category}", code="unknown_category")
        return category

    async def set_budget(self, category: str, limit: Decimal) -> tuple[str, Decimal]:
        self._check_category(category)
        paise = to_paise(limit)
        if paise <= 0:
            raise ValidationFailed("the budget must be more than zero", code="invalid_amount")
        async with self._sf() as session:
            row = await session.scalar(
                select(FinanceBudget).where(
                    FinanceBudget.category == category, FinanceBudget.period == "monthly"
                )
            )
            if row is None:
                row = FinanceBudget(id=new_id("fbud"), category=category, period="monthly", limit_paise=paise)
                session.add(row)
            row.limit_paise, row.updated_at = paise, self._clock.now()
            await session.commit()
            return row.id, from_paise(paise)

    async def budget_status(self, period: Period, category: str | None = None) -> BudgetStatus:
        async with self._sf() as session:
            stmt = select(FinanceBudget).where(FinanceBudget.period == "monthly")
            if category:
                stmt = stmt.where(FinanceBudget.category == category)
            budgets = (await session.scalars(stmt.order_by(FinanceBudget.category))).all()
        spent_by = {c: s for c, s, _ in await self._analytics.by_category(period)}
        config = self._categories.current()
        items: list[BudgetStatusItem] = []
        for b in budgets:
            spent = sum(spent_by.values()) if b.category == "all" else spent_by.get(b.category, 0)
            used = pct(spent, b.limit_paise)
            state = "exceeded" if spent > b.limit_paise else "warning" if used >= WARNING_PCT else "ok"
            items.append(BudgetStatusItem(
                category=b.category, name="all spending" if b.category == "all" else config.name(b.category),
                limit=from_paise(b.limit_paise), spent=from_paise(spent),
                remaining=from_paise(b.limit_paise - spent), used_pct=used, state=state,
            ))  # fmt: skip
        return BudgetStatus(period=period, items=items)

    # ------------------------------------------------------------ categories

    async def recategorize(
        self, transaction_id: str, category: str, *, apply_to_merchant: bool
    ) -> tuple[TransactionOut, int]:
        """Owner override. With `apply_to_merchant` the override becomes a rule for the merchant and
        updates its other non-overridden rows. Returns (transaction, rows changed)."""
        if self._categories.current().get(category) is None:
            raise ValidationFailed(f"unknown category: {category}", code="unknown_category")
        from app.finance.analytics import to_out

        async with self._sf() as session:
            txn = await session.get(T, transaction_id)
            if txn is None:
                raise NotFound("No such transaction.", code="transaction_not_found")
            txn.category, txn.category_source, txn.confidence = category, "override", 100
            changed = 1
            if apply_to_merchant:
                rule = await session.get(FinanceCategoryRule, txn.merchant_key)
                if rule is None:
                    session.add(FinanceCategoryRule(merchant_key=txn.merchant_key, category=category,
                                                    created_at=self._clock.now()))  # fmt: skip
                else:
                    rule.category = category
                others = (await session.scalars(
                    select(T).where(T.merchant_key == txn.merchant_key, T.id != txn.id)
                )).all()  # fmt: skip
                for other in others:
                    other.category, other.category_source, other.confidence = category, "override", 100
                changed += len(others)
            await session.commit()
            return to_out(txn), changed

    async def overrides(self) -> dict[str, str]:
        async with self._sf() as session:
            return await load_overrides(session)

    # ------------------------------------------------------------ alerts

    async def alerts(self, as_of: date, month: Period) -> AlertList:
        alerts: list[Alert] = []
        for item in (await self.budget_status(month)).items:
            if item.state == "exceeded":
                alerts.append(Alert(kind="budget_exceeded", category=item.category, amount=item.spent,
                                    message=f"{item.name}: spent {item.spent} of {item.limit} in {month.label_en}"))  # fmt: skip
        points = await self.points(as_of)
        debits = sorted((p for p in points if p.direction == "debit"), key=lambda p: (p.txn_date, p.id))
        recent_start = as_of - timedelta(days=29)
        for p in debits:
            if p.txn_date < recent_start or p.paise < UNUSUAL_MIN_PAISE:
                continue
            history = [q.paise for q in debits
                       if q.category == p.category and as_of - timedelta(days=210) <= q.txn_date < recent_start]  # fmt: skip
            if len(history) >= UNUSUAL_MIN_SAMPLES and p.paise > UNUSUAL_FACTOR * median_low(history):
                alerts.append(Alert(kind="unusual_spend", category=p.category, merchant=p.merchant,
                                    amount=from_paise(p.paise), transaction_ids=[p.id], date=p.txn_date,
                                    message=f"{p.merchant} {from_paise(p.paise)} is over {UNUSUAL_FACTOR}x your usual {p.category} spend"))  # fmt: skip
        first_seen: dict[str, date] = {}
        for p in debits:
            first_seen.setdefault(p.merchant_key, p.txn_date)
        flagged: set[str] = set()
        for rec in detect_recurring(points, as_of):
            if rec.is_subscription and rec.first_date >= as_of - timedelta(days=70):
                flagged.add(rec.merchant_key)
        for p in debits:
            if p.category == "subscriptions" and first_seen[p.merchant_key] >= as_of - timedelta(days=35):
                flagged.add(p.merchant_key)
        for key in sorted(flagged):
            last = [p for p in debits if p.merchant_key == key][-1]
            alerts.append(Alert(kind="new_subscription", merchant=last.merchant, category=last.category,
                                amount=from_paise(last.paise), date=last.txn_date, transaction_ids=[last.id],
                                message=f"New subscription: {last.merchant} {from_paise(last.paise)}"))  # fmt: skip
        recent = [
            p
            for p in debits
            if p.txn_date >= recent_start and not p.merchant_key.startswith(("unknown", "upi payee"))
        ]
        for i, a in enumerate(recent):
            for b in recent[i + 1 :]:
                if (
                    b.merchant_key == a.merchant_key
                    and b.paise == a.paise
                    and (b.txn_date - a.txn_date).days <= 1
                ):
                    alerts.append(Alert(kind="possible_duplicate_charge", merchant=a.merchant,
                                        amount=from_paise(a.paise), transaction_ids=[a.id, b.id], date=b.txn_date,
                                        message=f"{a.merchant} charged {from_paise(a.paise)} twice"))  # fmt: skip
        return AlertList(as_of=as_of, alerts=alerts)
