"""Writes the JSON fixtures the ZoroCommerce tests decode, built from the backend's real Pydantic models
and pure functions, so the Swift DTOs cannot drift from the server.

Run from the backend directory:
    cd backend && uv run --no-sync python ../ios/Packages/ZoroCommerce/scripts/generate_fixtures.py

All values here are test data and live only under ZoroCommerce/Tests/**.
"""

from __future__ import annotations

import json
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

from pydantic import BaseModel

from app.core.types import IntegrationLevel
from app.finance.periods import Period
from app.finance.schemas import (
    Alert,
    AlertList,
    BudgetStatus,
    BudgetStatusItem,
    CashflowForecast,
    CategoryBreakdown,
    CategoryTotal,
    ForecastLine,
    ImportStatus,
    IncomeExpense,
    MonthRow,
    RecurringItem,
    RecurringReport,
    RowIssue,
    SpendingSummary,
    TransactionList,
    TransactionOut,
)
from app.finance.summaries import summary_card, transactions_card
from app.investment.api import ImportResult
from app.investment.backtest import BacktestMetrics, BacktestResult, BacktestTrade, EquityPoint
from app.investment.paper import PaperBook, PaperPosition, PaperTradeOut
from app.investment.research import AnalystSection, Interpretation, StockAnalysis
from app.investment.schemas import (
    HoldingView,
    PerformancePoint,
    PerformanceReport,
    PortfolioSummary,
    RiskExposure,
    TaxEstimate,
    UnusualMovement,
)
from app.investment.summaries import analysis_card, portfolio_card
from app.investment.tool_models import UnusualMovementsOut, WatchItemView, WatchlistAddOut, WatchlistOut
from app.investment.verify import Fact, VerificationReport
from app.schemas.common import UICard
from app.schemas.turns import ApprovalRequest
from app.shopping.basket import BasketItemView, BasketView
from app.shopping.compare import BasketLineIn, FeeRule, OfferIn, ProviderInput, compare_basket
from app.shopping.http import ToolRun
from app.shopping.present import ShownProduct, VariantOut, products_card
from app.shopping.service import CheckoutCheck, CheckoutResult
from app.shopping.shortlist import ShortlistEntry
from app.shopping.tools_basket import BasketChangeOut, BasketViewOut, RecordPriceOut
from app.shopping.tools_catalog import CompareOut, SearchOut
from app.shopping.types import Handoff, MethodLevel, ProviderInfo, ProviderMethod, Unavailable

ROOT = Path(__file__).resolve().parents[1] / "Tests"
NOW = datetime(2026, 11, 13, 9, 30, tzinfo=UTC)
STALENESS = {"provider_api": 60, "user_reported": 1440, "user_screenshot_ocr": 1440}


def dump(value: Any) -> Any:
    if isinstance(value, BaseModel):
        return value.model_dump(mode="json")
    if isinstance(value, list):
        return [dump(v) for v in value]
    return value


def write(target: str, name: str, value: Any) -> None:
    folder = ROOT / target / "Fixtures"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.json").write_text(json.dumps(dump(value), indent=2, ensure_ascii=False) + "\n")


def card(c: UICard | None) -> dict[str, Any]:
    assert c is not None
    return c.model_dump(mode="json")


# ------------------------------------------------------------------------------------------- shopping


def shopping() -> None:
    t = "ShoppingInterfaceTests"
    product = ShownProduct(
        index=1, ref="swiggy_instamart:p-101", provider="swiggy_instamart", product_id="p-101",
        name="Test toned milk", brand="Test dairy", url=None,
        variants=[
            VariantOut(variant_id="v-1", label="500 ml", price=Decimal("29.00"), mrp=Decimal("30.00"),
                       unit_price="₹5.80 per 100 ml", in_stock=True),
            VariantOut(variant_id="v-2", label="1 l", price=Decimal("56.50"), in_stock=None),
        ],
        attributes={"fat_content": "3%"}, source="swiggy_instamart:search_products",
        retrieved_at=NOW - timedelta(minutes=5),
    )  # fmt: skip
    second = product.model_copy(update={
        "index": 2, "ref": "swiggy_instamart:p-102", "product_id": "p-102", "name": "Test curd", "brand": None,
        "variants": [VariantOut(variant_id="v-9", label="400 g", price=Decimal("45.00"), in_stock=False)],
    })  # fmt: skip
    unavailable = Unavailable(
        provider="zepto", method=ProviderMethod.SEARCH_PRODUCTS, reason="requires_partnership",
        message="Zepto has no public search API.",
        handoff=Handoff(provider="zepto", title="Open Zepto", url="https://www.zepto.com/", verified=False),
    )  # fmt: skip
    search = SearchOut(query="milk", products=[product, second], unavailable=[unavailable])
    write(t, "search_out", search)
    write(t, "card_products", card(products_card(search.products, search.query)))

    item = BasketItemView(
        item_id="bi-1", name="Test toned milk", brand="Test dairy", size="500 ml", identity_key="milk-500ml",
        gtin=None, sku="v-1", selected_variant={"variant_id": "v-1", "label": "500 ml"}, quantity=2,
        preferred_brand=None, substitutions_allowed=False, equivalence_confidence_pct=100,
        unit_price=Decimal("29.00"), price_at=NOW - timedelta(minutes=5),
        price_source="swiggy_instamart:search_products", available_retailers=[{"provider": "swiggy_instamart"}],
    )  # fmt: skip
    item2 = item.model_copy(update={
        "item_id": "bi-2", "name": "Test eggs", "brand": None, "size": "6 pcs", "identity_key": "eggs-6",
        "sku": None, "selected_variant": None, "quantity": 1, "substitutions_allowed": True,
        "equivalence_confidence_pct": 80, "unit_price": None, "price_at": None, "price_source": None,
        "available_retailers": [],
    })  # fmt: skip
    basket = BasketView(
        basket_id="bk-1", name="Groceries", customer_location_reference="home", original_provider="swiggy_instamart",
        items=[item, item2], priced_items=1, known_total=Decimal("58.00"),
        created_at=NOW - timedelta(hours=1), updated_at=NOW,
    )  # fmt: skip
    write(t, "basket_view_out", BasketViewOut(basket=basket))
    write(t, "basket_view_empty", BasketViewOut(basket=None))
    write(t, "basket_change_out", BasketChangeOut(status="updated", item=item, basket=basket))
    write(t, "card_basket", UICard(kind="basket", title=basket.name, payload=basket.model_dump(mode="json")))

    lines = [
        BasketLineIn(item_id="bi-1", name="Test toned milk", quantity=2),
        BasketLineIn(item_id="bi-2", name="Test eggs", quantity=1, substitutions_allowed=True),
    ]
    fresh, old = NOW - timedelta(minutes=10), NOW - timedelta(hours=5)

    def offer(item_id: str, paise: int, at: datetime, kind: str = "exact", label: str = "") -> OfferIn:
        return OfferIn(item_id=item_id, match_kind=kind, confidence=0.9 if kind == "exact" else 0.6,  # type: ignore[arg-type]
                       reasons=["same size"] if kind == "substitute" else [], unit_price_paise=paise,
                       observed_at=at, provenance="provider_api", source="test:search_products",
                       in_stock=True, label=label)  # fmt: skip

    def fee(paise: int, waived_at: int | None = None) -> FeeRule:
        return FeeRule(kind="delivery_fee", label="Delivery fee", amount_paise=paise,
                       waived_at_or_above_paise=waived_at, observed_at=fresh, provenance="provider_api",
                       source="test:get_delivery_fee")  # fmt: skip

    handoff_a = Handoff(provider="store_a", title="Open Store A", url="https://example.invalid/a", verified=True)
    store_a = ProviderInput(provider="store_a", title="Store A", queryable=True, handoff=handoff_a,
                            offers=[offer("bi-1", 2900, fresh), offer("bi-2", 6000, fresh)], fees=[fee(2500)])  # fmt: skip
    store_b = ProviderInput(provider="store_b", title="Store B", queryable=True,
                            offers=[offer("bi-1", 2800, fresh), offer("bi-2", 6500, fresh)], fees=[fee(3000, 10000)])  # fmt: skip
    store_c = ProviderInput(provider="store_c", title="Store C", queryable=True,
                            offers=[offer("bi-1", 2700, fresh), offer("bi-2", 5500, old),
                                    offer("bi-2", 5200, fresh, "substitute", "Test brown eggs 6 pcs")], fees=None)  # fmt: skip
    store_d = ProviderInput(provider="store_d", title="Store D", queryable=False,
                            handoff=Handoff(provider="store_d", title="Open Store D"))  # fmt: skip
    ranked = compare_basket(lines, [store_a, store_b, store_c, store_d], NOW, STALENESS)
    write(t, "compare_out_cheapest", CompareOut(basket=basket, comparison=ranked))
    write(t, "card_basket_comparison", UICard(kind="basket_comparison", title="Basket comparison",
                                              payload=ranked.model_dump(mode="json")))  # fmt: skip
    partial = compare_basket(lines, [store_c, store_d], NOW, STALENESS)
    write(t, "compare_out_partial", CompareOut(basket=basket, comparison=partial))
    unknown_fees = compare_basket(lines, [store_a.model_copy(update={"fees": None}), store_b], NOW, STALENESS)
    write(t, "compare_out_fees_unknown", CompareOut(basket=basket, comparison=unknown_fees))
    write(t, "compare_out_empty", CompareOut(basket=None, comparison=None))

    checkout = CheckoutResult(
        status="handoff", provider="store_a", reason="",
        checks=[CheckoutCheck(check="payable_matches", ok=True, detail="₹113.00")],
        final_payable=Decimal("113.00"), provider_to_pay=None, handoff=handoff_a, warnings=[],
    )  # fmt: skip
    write(t, "checkout_completed", ToolRun(status="completed", result=checkout.model_dump(mode="json")))
    rejected = CheckoutResult(status="rejected", provider="store_a", reason="payable_changed",
                              checks=[CheckoutCheck(check="payable_matches", ok=False, detail="now ₹118.00")])  # fmt: skip
    write(t, "checkout_rejected", ToolRun(status="completed", result=rejected.model_dump(mode="json")))
    approval = ApprovalRequest(
        approval_id="ap-1", tool="shopping.prepare_checkout", risk="high", level="confirm",
        title="Prepare your Store A cart", summary="Replace your Store A cart with this basket.",
        details=[], action_digest="ab" * 32, expires_at=NOW + timedelta(minutes=5),
    )  # fmt: skip
    write(t, "checkout_needs_approval", ToolRun(status="needs_approval", approval=approval))

    write(t, "record_price_out", RecordPriceOut(status="recorded", observation_id="ob-1", provider="store_b",
                                                kind="item", price=Decimal("31.50"), provenance="user_reported",
                                                observed_at=NOW))  # fmt: skip
    providers = [
        ProviderInfo(id="swiggy_instamart", title="Swiggy Instamart", category="quick_commerce",
                     status="working_integration",
                     methods=[MethodLevel(method=ProviderMethod.SEARCH_PRODUCTS, level=IntegrationLevel.OFFICIAL_API),
                              MethodLevel(method=ProviderMethod.PREPARE_CHECKOUT, level=IntegrationLevel.DEEP_LINK_HANDOFF,
                                          note="Payment in the Instamart app")]),
        ProviderInfo(id="zepto", title="Zepto", category="quick_commerce", status="requires_partnership",
                     methods=[MethodLevel(method=ProviderMethod.SEARCH_PRODUCTS, level=IntegrationLevel.UNAVAILABLE)],
                     handoff=unavailable.handoff, note="No public API."),
    ]  # fmt: skip
    write(t, "providers", providers)
    write(t, "shortlist", [ShortlistEntry(
        entry_id="sli-1", provider="swiggy_instamart", product_id="p-101", variant_id="v-1", name="Test toned milk",
        brand="Test dairy", url=None, price=Decimal("29.00"), attributes={"size": "500 ml"},
        source="swiggy_instamart:search_products", retrieved_at=NOW)])  # fmt: skip


# ------------------------------------------------------------------------------------------- finance


def finance() -> None:
    t = "FinancialInterfaceTests"
    month = Period(key="this_month", start=date(2026, 11, 1), end=date(2026, 11, 30), label_en="this month",
                   label_hi="इस महीने", label_hinglish="is mahine")  # fmt: skip
    cats = [
        CategoryTotal(category="groceries", name="Groceries", amount=Decimal("4200.50"), count=6, share_pct=Decimal("60.0")),
        CategoryTotal(category="transport", name="Transport", amount=Decimal("2800.00"), count=4, share_pct=Decimal("40.0")),
    ]  # fmt: skip
    summary = SpendingSummary(period=month, spent=Decimal("7000.50"), received=Decimal("85000.00"),
                              net=Decimal("77999.50"), transactions=12, top_categories=cats)  # fmt: skip
    write(t, "summary", summary)
    write(t, "card_finance_summary", card(summary_card(summary)))
    write(t, "breakdown", CategoryBreakdown(period=month, direction="debit", total=Decimal("7000.50"),
                                            transactions=10, categories=cats))  # fmt: skip
    year = month.model_copy(update={"key": "this_year", "start": date(2026, 1, 1), "end": date(2026, 12, 31),
                                    "label_en": "this year"})  # fmt: skip
    ie = IncomeExpense(period=year, income=Decimal("170000.00"), expense=Decimal("14000.75"),
                       net=Decimal("155999.25"), savings_rate_pct=Decimal("91.8"),
                       months=[MonthRow(month="2026-10", income=Decimal("85000.00"), expense=Decimal("7000.25"),
                                        net=Decimal("77999.75")),
                               MonthRow(month="2026-11", income=Decimal("85000.00"), expense=Decimal("7000.50"),
                                        net=Decimal("77999.50"))])  # fmt: skip
    write(t, "income_expense", ie)
    write(t, "card_income_expense", card(summary_card(ie)))

    def tx(i: int, amount: str, direction: str = "debit") -> TransactionOut:
        return TransactionOut(id=f"tx-{i}", account_id="acc-1", date=date(2026, 11, i), value_date=None,
                              narration=f"UPI/TEST/{i}", counterparty=f"Test merchant {i}", vpa=None, upi_ref=None,
                              channel="upi", direction=direction, amount=Decimal(amount),  # type: ignore[arg-type]
                              balance=None, category="groceries", category_source="rule", confidence=90,
                              source_file="statement.csv")  # fmt: skip

    last30 = month.model_copy(update={"key": "last_30_days", "label_en": "the last 30 days"})
    page1 = TransactionList(period=last30, total_debit=Decimal("300.75"), total_credit=Decimal("0.00"), count=3,
                            items=[tx(1, "100.25"), tx(2, "100.25")], next_cursor="2")  # fmt: skip
    page2 = TransactionList(period=last30, total_debit=Decimal("300.75"), total_credit=Decimal("0.00"), count=3,
                            items=[tx(3, "100.25")], next_cursor=None)  # fmt: skip
    write(t, "transactions_page1", page1)
    write(t, "transactions_page2", page2)
    write(t, "card_transactions", card(transactions_card(page1)))

    imp = ImportStatus(id="imp-1", filename="statement.csv", file_kind="csv", source_kind="bank_statement",
                       profile="generic_csv", account_id="acc-1", account_name="Savings", status="completed",
                       rows_total=12, rows_imported=10, rows_duplicate=2, rows_reconciled=0, rows_skipped=0,
                       rows_error=0, balance_check="ok", message="Imported 10 transactions.",
                       period_start=date(2026, 10, 1), period_end=date(2026, 10, 31), created_at=NOW)  # fmt: skip
    write(t, "import_completed", imp)
    write(t, "import_failed", imp.model_copy(update={
        "id": "imp-2", "status": "failed", "rows_imported": 0, "rows_duplicate": 0, "rows_error": 12,
        "balance_check": "not_available", "message": "No transactions could be read.",
        "errors": [RowIssue(line=2, reason="date not recognised")], "period_start": None, "period_end": None}))  # fmt: skip
    write(t, "imports", [imp])

    budgets = BudgetStatus(period=month, items=[
        BudgetStatusItem(category="groceries", name="Groceries", limit=Decimal("5000.00"), spent=Decimal("4200.50"),
                         remaining=Decimal("799.50"), used_pct=Decimal("84.0"), state="warning"),
        BudgetStatusItem(category="transport", name="Transport", limit=Decimal("2000.00"), spent=Decimal("2800.00"),
                         remaining=Decimal("-800.00"), used_pct=Decimal("140.0"), state="exceeded"),
    ])  # fmt: skip
    write(t, "budgets", budgets)
    write(t, "card_budgets", card(summary_card(budgets)))
    recurring = RecurringReport(as_of=date(2026, 11, 13), monthly_total=Decimal("649.00"), items=[
        RecurringItem(merchant="Test streaming", merchant_key="test-streaming", category="entertainment",
                      direction="debit", cadence="monthly", typical_amount=Decimal("649.00"),
                      min_amount=Decimal("649.00"), max_amount=Decimal("649.00"), occurrences=4,
                      first_date=date(2026, 8, 3), last_date=date(2026, 11, 3), next_expected=date(2026, 12, 3),
                      is_subscription=True)])  # fmt: skip
    write(t, "recurring", recurring)
    forecast = CashflowForecast(as_of=date(2026, 11, 13), horizon_days=30, start=date(2026, 11, 14),
                                end=date(2026, 12, 13), expected_outflow=Decimal("7649.00"),
                                outflow_low=Decimal("6500.00"), outflow_high=Decimal("9100.00"),
                                expected_inflow=Decimal("85000.00"), net=Decimal("77351.00"),
                                method="recurring payments plus trailing 90-day average of other spending",
                                lines=[ForecastLine(label="Test streaming", direction="debit", amount=Decimal("649.00"),
                                                    basis="recurring:monthly")])  # fmt: skip
    write(t, "forecast", forecast)
    write(t, "card_forecast", card(summary_card(forecast)))
    write(t, "alerts", AlertList(as_of=date(2026, 11, 13), alerts=[
        Alert(kind="budget_exceeded", message="Transport is over its ₹2,000.00 budget.", category="transport",
              amount=Decimal("800.00")),
        Alert(kind="possible_duplicate_charge", message="Two equal charges from Test merchant 1 on 1 Nov.",
              merchant="Test merchant 1", amount=Decimal("100.25"), transaction_ids=["tx-1", "tx-9"],
              date=date(2026, 11, 1)),
    ]))  # fmt: skip


# ------------------------------------------------------------------------------------------- investments


def investments() -> None:
    t = "InvestmentsFeatureTests"
    h1 = HoldingView(symbol="TESTA", exchange="NSE", quantity=Decimal("10"), average_price=Decimal("100.00"),
                     invested=Decimal("1000.00"), last_price=Decimal("120.50"), price_source="csv",
                     price_as_of=NOW - timedelta(days=1), value=Decimal("1205.00"), pnl=Decimal("205.00"),
                     pnl_percent=Decimal("20.50"), weight_percent=Decimal("70.62"), source="csv")  # fmt: skip
    h2 = HoldingView(symbol="TESTB", exchange="NSE", quantity=Decimal("5"), average_price=Decimal("110.00"),
                     invested=Decimal("550.00"), last_price=Decimal("100.20"), price_source="csv",
                     price_as_of=NOW - timedelta(days=1), value=Decimal("501.00"), pnl=Decimal("-49.00"),
                     pnl_percent=Decimal("-8.91"), weight_percent=Decimal("29.38"), source="csv")  # fmt: skip
    h3 = HoldingView(symbol="TESTC", exchange="BSE", quantity=Decimal("2"), average_price=Decimal("50.00"),
                     invested=Decimal("100.00"), source="csv")  # fmt: skip
    portfolio = PortfolioSummary(
        as_of=NOW, holdings=[h1, h2, h3], holdings_count=3, priced_count=2, invested=Decimal("1550.00"),
        value=Decimal("1706.00"), pnl=Decimal("156.00"), pnl_percent=Decimal("10.06"), hhi=Decimal("0.5851"),
        effective_holdings=Decimal("1.71"), concentration_flags=["TESTA is 70.6% of the priced portfolio"],
        top_holding="TESTA", top_weight_percent=Decimal("70.62"),
        risk=RiskExposure(status="unavailable", reason="fewer than 60 shared daily bars"),
        sources=["csv"], unpriced=["BSE:TESTC"],
    )  # fmt: skip
    write(t, "portfolio", portfolio)
    write(t, "card_portfolio", card(portfolio_card(portfolio)))
    write(t, "performance", PerformanceReport(points=[
        PerformancePoint(taken_at=NOW - timedelta(days=7), value=Decimal("1650.00"), invested=Decimal("1550.00")),
        PerformancePoint(taken_at=NOW, value=Decimal("1706.00"), invested=Decimal("1550.00"))],
        change=Decimal("56.00"), change_percent=Decimal("3.39")))  # fmt: skip
    write(t, "import_result", ImportResult(imported=3, updated=0, source="csv"))
    write(t, "watchlists", ["default", "banks"])
    write(t, "watchlist", WatchlistOut(list_name="default", items=[
        WatchItemView(symbol="TESTA", exchange="NSE", note="", added_at=NOW - timedelta(days=3),
                      last_close=Decimal("120.50"), close_day=date(2026, 11, 12), change_percent=Decimal("1.25"),
                      price_source="csv"),
        WatchItemView(symbol="TESTD", exchange="NSE", note="results due", added_at=NOW)]))  # fmt: skip
    write(t, "watchlist_add", WatchlistAddOut(symbol="TESTD", exchange="NSE", list_name="default", added=True, size=2))
    write(t, "unusual", UnusualMovementsOut(movements=[
        UnusualMovement(symbol="TESTA", exchange="NSE", day=date(2026, 11, 12), close=Decimal("120.50"),
                        return_percent=6.2, return_z=3.1, volume=120000, volume_z=2.4,
                        reasons=["return 3.1 standard deviations above normal"], source="csv")],
        checked=3, missing_data=["BSE:TESTC"], return_z_threshold=Decimal("2.5"),
        volume_z_threshold=Decimal("2.0"), window=60))  # fmt: skip
    names = ["fundamental", "technical", "news_sentiment", "quantitative", "risk", "portfolio_manager", "verification"]
    sections = [AnalystSection(analyst=n, title=n.replace("_", " ").capitalize(),  # type: ignore[arg-type]
                               status="ok" if n not in ("fundamental", "news_sentiment") else "unavailable",
                               findings=[f"{n} finding"] if n not in ("fundamental", "news_sentiment") else [],
                               sources=["csv"], reason="" if n not in ("fundamental", "news_sentiment")
                               else "no fundamentals source configured") for n in names]  # fmt: skip
    analysis = StockAnalysis(
        symbol="TESTA", exchange="NSE", generated_at=NOW, last_bar=date(2026, 11, 12),
        freshness="Last daily bar 12 Nov 2026 (1 day old).", data_sources=["csv"], sections=sections,
        facts=[Fact(key="close", label="Last close", value=Decimal("120.50"), unit="INR", source="csv",
                    as_of=date(2026, 11, 12))],
        verification=VerificationReport(passed=True, numbers_checked=4, problems=[], banned_phrases=[]),
        interpretation=Interpretation(status="not_requested"),
    )  # fmt: skip
    write(t, "analysis", analysis)
    write(t, "card_stock_analysis", card(analysis_card(analysis)))
    backtest = BacktestResult(
        symbol="TESTA", exchange="NSE", strategy="sma_crossover", params={"fast": 20, "slow": 50},
        start=date(2025, 1, 1), end=date(2026, 11, 12), bars=470, initial_capital=Decimal("100000.00"),
        final_equity=Decimal("112345.67"), total_return_percent=Decimal("12.35"), total_costs=Decimal("845.20"),
        slippage_bps=Decimal("5"), product="delivery",
        trades=[BacktestTrade(day=date(2025, 3, 4), side="buy", quantity=800, price=Decimal("110.00"),
                              charges=Decimal("120.10"), signal_day=date(2025, 3, 3))],
        open_quantity=800,
        metrics=BacktestMetrics(cagr_percent=6.4, sharpe=0.71, sortino=0.95, max_drawdown_percent=-14.2,
                                volatility_percent=18.3, win_rate_percent=50.0, round_trips=2, turnover=1.8,
                                exposure_percent=62.0),
        tax_estimate=TaxEstimate(short_term_gain=Decimal("0"), long_term_gain=Decimal("0"), stcg_tax=Decimal("0"),
                                 ltcg_tax=Decimal("0"), total_tax=Decimal("0"), basis="test basis"),
        data_source="csv", charges_source="config/investment.yaml", charges_verified_on="2026-11-01",
        assumptions=["Signals act on the next bar's open."], fingerprint="f" * 16,
        equity_curve=[EquityPoint(day=date(2025, 1, 1), equity=Decimal("100000.00")),
                      EquityPoint(day=date(2026, 11, 12), equity=Decimal("112345.67"))],
    )  # fmt: skip
    write(t, "backtest", backtest)
    trade = PaperTradeOut(id="pt-1", symbol="TESTA", exchange="NSE", side="buy", product="delivery", quantity=5,
                          price=Decimal("120.56"), charges=Decimal("1.20"), reference_price=Decimal("120.50"),
                          price_source="csv", price_as_of=NOW - timedelta(days=1), executed_at=NOW)  # fmt: skip
    write(t, "paper_trade", trade)
    write(t, "paper_book", PaperBook(positions=[PaperPosition(symbol="TESTA", exchange="NSE", quantity=5,
                                                              average_cost=Decimal("120.80"),
                                                              realised_pnl=Decimal("0.00"),
                                                              charges_paid=Decimal("1.20"))],
                                     trades=[trade], realised_pnl=Decimal("0.00"), charges_paid=Decimal("1.20")))  # fmt: skip


if __name__ == "__main__":
    shopping()
    finance()
    investments()
    print("fixtures written under", ROOT)
