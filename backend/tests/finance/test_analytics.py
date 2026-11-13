from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest
from sqlalchemy import select

from app.finance.analytics import SearchFilters
from app.finance.models import FinanceTransaction
from app.finance.periods import resolve_period
from app.plugins import PluginRegistry
from tests.finance.data import history_csv

D = Decimal
TODAY = date(2026, 11, 13)


@pytest.fixture
async def seeded(registry: PluginRegistry) -> PluginRegistry:
    result = await registry.service("finance_imports").import_file(
        "history.csv", history_csv(), account_name="Main"
    )
    assert result.status == "completed" and result.balance_check == "ok"
    return registry


async def test_category_aggregation_equals_sum_of_rows(seeded: PluginRegistry) -> None:
    period = resolve_period("2026-11", TODAY)
    breakdown = await seeded.service("finance_analytics").category_breakdown(period)
    async with seeded.service("session_factory")() as s:
        rows = (await s.scalars(select(FinanceTransaction).where(
            FinanceTransaction.txn_month == "2026-11", FinanceTransaction.direction == "debit"))).all()  # fmt: skip
    by_cat: dict[str, int] = {}
    for r in rows:
        by_cat[r.category] = by_cat.get(r.category, 0) + r.amount_paise
    assert {c.category: int(c.amount * 100) for c in breakdown.categories} == by_cat
    assert (
        breakdown.total
        == sum((c.amount for c in breakdown.categories), D("0"))
        == D(sum(by_cat.values())) / 100
    )
    assert breakdown.transactions == len(rows)
    assert by_cat["food"] == 135000 and by_cat["shopping"] == 900000
    assert all(
        isinstance(c.amount, Decimal) and isinstance(c.share_pct, Decimal) for c in breakdown.categories
    )


async def test_spending_summary_and_income_expense(seeded: PluginRegistry) -> None:
    analytics = seeded.service("finance_analytics")
    oct_ = await analytics.spending_summary(resolve_period("2026-10", TODAY))
    assert (oct_.spent, oct_.received, oct_.transactions) == (
        D("649.00") + D("1490.00") + D("800.00"),
        D("100000.00"),
        4,
    )
    food = await analytics.spending_summary(resolve_period("this_month", TODAY), "food")
    assert food.spent == D("1350.00") and food.category_name == "food and dining"
    ie = await analytics.income_expense(resolve_period("this_year", TODAY))
    assert [m.month for m in ie.months][:2] == ["2026-01", "2026-02"] and len(ie.months) == 11
    assert ie.income == D("600000.00")
    assert ie.expense == sum((m.expense for m in ie.months), D("0"))
    assert ie.net == ie.income - ie.expense and ie.savings_rate_pct is not None


async def test_merchant_report_and_search(seeded: PluginRegistry) -> None:
    analytics = seeded.service("finance_analytics")
    report = await analytics.merchant_report(resolve_period("this_year", TODAY), "swiggy")
    assert (report.merchant, report.total, report.count, report.average) == (
        "Swiggy",
        D("1550.00"),
        3,
        D("516.67"),
    )
    found = await analytics.search(
        resolve_period("this_month", TODAY), SearchFilters(merchant="Uber"), limit=1
    )
    assert (
        found.count == 2
        and len(found.items) == 1
        and found.next_cursor == "1"
        and found.total_debit == D("500.00")
    )
    page2 = await analytics.search(
        resolve_period("this_month", TODAY), SearchFilters(merchant="Uber"), limit=1, offset=1
    )
    assert page2.next_cursor is None and page2.items[0].id != found.items[0].id
    big = await analytics.search(resolve_period("this_year", TODAY), SearchFilters(min_paise=500000))
    assert {t.counterparty for t in big.items} == {"Acme Corp", "Amazon"}


async def test_recurring_detection(seeded: PluginRegistry) -> None:
    report = await seeded.service("finance_insights").recurring(TODAY)
    items = {i.merchant_key: i for i in report.items}
    netflix = items["netflix"]
    assert (netflix.cadence, netflix.typical_amount, netflix.occurrences, netflix.is_subscription) == (
        "monthly", D("649.00"), 6, True)  # fmt: skip
    assert netflix.next_expected == date(2026, 12, 5)
    bescom = items["bescom"]
    assert (
        bescom.cadence == "monthly" and not bescom.is_subscription and bescom.typical_amount == D("1500.00")
    )
    assert items["acme corp"].direction == "credit"
    assert "amazon" not in items  # the 9,000 order breaks the amount tolerance
    assert report.monthly_total == D("649.00") + D("1500.00")


async def test_forecast_is_deterministic_and_explained(seeded: PluginRegistry) -> None:
    insights = seeded.service("finance_insights")
    first = await insights.forecast(TODAY, 30)
    second = await insights.forecast(TODAY, 30)
    assert first == second
    debit_lines = sum((line.amount for line in first.lines if line.direction == "debit"), D("0"))
    assert first.expected_outflow == debit_lines
    assert first.outflow_low <= first.expected_outflow <= first.outflow_high
    assert first.expected_inflow == D("100000.00")  # December salary, recurring credit only
    assert {line.basis for line in first.lines} >= {"recurring:monthly", "trailing_average"}
    assert "90 days" in first.method
    assert all(isinstance(v, Decimal) for v in (first.expected_outflow, first.net, first.outflow_low))


async def test_budget_progress_and_alerts(seeded: PluginRegistry) -> None:
    insights = seeded.service("finance_insights")
    await insights.set_budget("food", D("1000"))
    await insights.set_budget("shopping", D("20000.00"))
    status = await insights.budget_status(resolve_period("this_month", TODAY))
    food = next(i for i in status.items if i.category == "food")
    assert (food.spent, food.remaining, food.used_pct, food.state) == (
        D("1350.00"),
        D("-350.00"),
        D("135.0"),
        "exceeded",
    )
    shopping = next(i for i in status.items if i.category == "shopping")
    assert (shopping.used_pct, shopping.state) == (D("45.0"), "ok")
    alerts = await insights.alerts(TODAY, resolve_period("this_month", TODAY))
    kinds = {(a.kind, a.category or a.merchant) for a in alerts.alerts}
    assert ("budget_exceeded", "food") in kinds
    assert ("unusual_spend", "shopping") in kinds
    assert any(a.kind == "new_subscription" and a.merchant == "Spotify" for a in alerts.alerts)
    assert ("possible_duplicate_charge", "Uber") in kinds
    assert not any(a.kind == "new_subscription" and a.merchant == "Netflix" for a in alerts.alerts)


async def test_unknown_category_budget_rejected(seeded: PluginRegistry) -> None:
    from app.core.errors import ValidationFailed

    with pytest.raises(ValidationFailed):
        await seeded.service("finance_insights").set_budget("yachts", D("10"))


async def test_owner_override_becomes_rule_for_future_imports(seeded: PluginRegistry) -> None:
    from tests.finance.samples import generic_csv

    analytics, insights = seeded.service("finance_analytics"), seeded.service("finance_insights")
    store = await analytics.search(
        resolve_period("this_month", TODAY), SearchFilters(merchant="Kumar Stores")
    )
    assert store.items[0].category == "uncategorised"
    out, changed = await insights.recategorize(store.items[0].id, "groceries", apply_to_merchant=True)
    assert (out.category, out.category_source, changed) == ("groceries", "override", 1)
    later = [
        (
            date(2026, 11, 12),
            "UPI/DR/427512349999/KUMAR STORES/SBIN/kumarstores@oksbi/Payment",
            None,
            D("40.00"),
            None,
        )
    ]
    await seeded.service("finance_imports").import_file("later.csv", generic_csv(later))
    again = await analytics.search(
        resolve_period("this_month", TODAY), SearchFilters(merchant="Kumar Stores")
    )
    assert {t.category for t in again.items} == {"groceries"} and again.count == 2
