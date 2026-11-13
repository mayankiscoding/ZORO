"""Portfolio maths, research team, verification analyst and banned-claims check."""

from __future__ import annotations

from datetime import UTC, date, datetime
from decimal import Decimal

import pytest

from app.core.types import DataClass, PrivacyMode, TaskClass
from app.investment.config import AnalyticsConfig
from app.investment.portfolio import concentration, risk_exposure, value_holdings
from app.investment.research import AnalystSection, interpret, technical_analyst
from app.investment.schemas import Instrument
from app.investment.services import InvestmentServices
from app.investment.store import StoredHolding
from app.investment.verify import FactSheet, banned_claims, check_numbers, verify_texts
from app.providers.types import NoPermittedModel
from tests.fakes.gateway import FakeGateway
from tests.investment.conftest import NOW
from tests.investment.samples import random_walk

D = Decimal


def holding(symbol: str, qty: str, avg: str, last: str | None, when: datetime | None = None) -> StoredHolding:
    return StoredHolding(symbol=symbol, exchange="NSE", quantity=D(qty), average_price=D(avg),
                         last_price=D(last) if last else None, price_as_of=when, source="csv")  # fmt: skip


def test_valuation_pnl_and_hhi_by_hand() -> None:
    t0 = datetime(2026, 11, 10, 10, tzinfo=UTC)
    views = value_holdings(
        [
            holding("AAA", "10", "100", "150", t0),
            holding("BBB", "5", "200", "100", t0),
            holding("CCC", "1", "50", None),
        ],
        {"NSE:BBB": (D("110"), datetime(2026, 11, 12, 10, tzinfo=UTC), "csv:file")},  # newer close wins
    )
    a, b, c = views
    assert (a.value, a.pnl, a.pnl_percent) == (D("1500.00"), D("500.00"), D("50.00"))
    assert (b.last_price, b.value, b.pnl, b.price_source) == (D("110"), D("550.00"), D("-450.00"), "csv:file")
    assert c.value is None and c.pnl is None  # unpriced: never valued at cost
    # weights 1500/2050, 550/2050 -> HHI = 0.5354 + 0.0720 = 0.6074 ; 1/HHI = 1.65
    hhi, effective = concentration([D("1500"), D("550")])
    assert hhi == D("0.6074") and effective == D("1.65")
    assert concentration([D("100")] * 4) == (D("0.2500"), D("4.00"))
    assert concentration([]) == (None, None)


def test_risk_exposure_needs_history() -> None:
    cfg = AnalyticsConfig()
    walk = random_walk(80)
    assert risk_exposure({"NSE:WALK": D(1)}, {"NSE:WALK": None}, D("1000"), cfg).status == "unavailable"
    ok = risk_exposure({"NSE:WALK": D(1)}, {"NSE:WALK": walk}, D("100000"), cfg)
    assert ok.status == "ok" and ok.observations == 79
    assert ok.var_1d_percent is not None and ok.var_1d_percent > 0 and ok.var_1d_amount is not None


async def test_portfolio_summary_from_store(svc: InvestmentServices) -> None:
    from app.investment.csv_import import parse_holdings
    from tests.investment.samples import HOLDINGS_CSV

    await svc.store.replace_holdings("csv", parse_holdings(HOLDINGS_CSV))
    walk = random_walk(80)
    await svc.store.upsert_bars(Instrument(symbol="WALK"), walk.candles, "file:walk.csv")
    summary = await svc.portfolio.summary(NOW)
    assert summary.holdings_count == 2 and summary.priced_count == 2 and summary.unpriced == []
    walk_view = next(h for h in summary.holdings if h.symbol == "WALK")
    assert walk_view.last_price == walk.candles[-1].close and walk_view.price_source == "csv:file:walk.csv"
    assert summary.value == sum((h.value or D(0) for h in summary.holdings), D(0))
    assert summary.pnl == summary.value - summary.invested
    assert sum((h.weight_percent or D(0) for h in summary.holdings), D(0)) == pytest.approx(
        D(100), abs=D("0.02")
    )
    assert summary.concentration_flags and summary.risk.status == "unavailable"  # TESTCO has no bars
    assert "not investment advice" in summary.disclaimer


def test_verification_catches_a_wrong_number() -> None:
    sheet = FactSheet()
    sheet.add("close", "Last close", D("1234.5"), "INR", "test", date(2026, 11, 12))
    sheet.add("rsi_14", "RSI", 61.27, "", "test", places=1)
    good = "Close ₹1,234.50 on 2026-11-12, RSI 61.3."
    assert check_numbers(good, sheet) == []
    assert check_numbers("Close ₹1,243.50 on 2026-11-12.", sheet) == ["1,243.50 does not match any fact"]
    assert check_numbers("Close ₹1,234.50 on 2026-11-11.", sheet) == [
        "date 2026-11-11 is not in the fact sheet"
    ]
    assert check_numbers("RSI ६१.३", sheet) == []  # Devanagari digits are checked too
    report = verify_texts([good, "RSI is 72.0"], sheet)
    assert not report.passed and report.problems == ["72.0 does not match any fact"]


def test_banned_claims() -> None:
    for text in ("Guaranteed returns of 20%", "this is a sure-shot profit", "You cannot lose here",
                 "पक्का मुनाफा मिलेगा", "isme pakka profit hai", "risk-free investment"):  # fmt: skip
        assert banned_claims(text), text
    assert banned_claims("The Sharpe ratio uses a risk-free rate of 6.5%.") == []
    assert banned_claims("Prices can fall further than past data shows.") == []


def test_technical_section_numbers_all_verify() -> None:
    sheet = FactSheet()
    section = technical_analyst(random_walk(120), sheet)
    assert section.status == "ok" and verify_texts(section.findings, sheet).passed


async def test_model_interpretation_is_verified() -> None:
    sheet = FactSheet()
    sheet.add("close", "Last close", D("500"), "INR", "test", date(2026, 11, 12))
    sections: list[AnalystSection] = []
    good = FakeGateway(["The stock last closed at ₹500.00."])
    out = await interpret(good, sheet, sections, privacy_mode=PrivacyMode.STRICT_PRIVATE, turn_id="t")
    assert out.status == "accepted" and good.requests[0].task is TaskClass.FINANCIAL_INTERPRETATION
    assert good.requests[0].data_classes == frozenset({DataClass.FINANCIAL})
    wrong = await interpret(FakeGateway(["It closed at ₹550 and will surely go up."]), sheet, sections,
                            privacy_mode=PrivacyMode.STRICT_PRIVATE, turn_id="t")  # fmt: skip
    assert (
        wrong.status == "rejected" and wrong.text is None and "550 does not match any fact" in wrong.problems
    )
    promise = await interpret(FakeGateway(["Guaranteed gains from ₹500.00."]), sheet, sections,
                              privacy_mode=PrivacyMode.STRICT_PRIVATE, turn_id="t")  # fmt: skip
    assert promise.status == "rejected"
    denied = await interpret(FakeGateway([NoPermittedModel(TaskClass.FINANCIAL_INTERPRETATION)]), sheet, sections,
                             privacy_mode=PrivacyMode.STRICT_PRIVATE, turn_id="t")  # fmt: skip
    assert denied.status == "not_permitted"
    assert (
        await interpret(None, sheet, sections, privacy_mode=PrivacyMode.STRICT_PRIVATE, turn_id=None)
    ).status == "unavailable"


async def test_full_analysis_has_seven_sections(svc: InvestmentServices) -> None:
    walk = random_walk(300)
    bench = random_walk(300, seed=3, symbol="NIFTYBEES")
    await svc.store.upsert_bars(Instrument(symbol="WALK"), walk.candles, "file:walk.csv")
    await svc.store.upsert_bars(Instrument(symbol="NIFTYBEES"), bench.candles, "file:bench.csv")
    report = await svc.analyse(Instrument(symbol="WALK"), NOW, benchmark=Instrument(symbol="NIFTYBEES"))
    names = [s.analyst for s in report.sections]
    assert names == ["fundamental", "technical", "news_sentiment", "quantitative", "risk", "portfolio_manager",
                     "verification"]  # fmt: skip
    status = {s.analyst: s.status for s in report.sections}
    assert status["fundamental"] == "unavailable" and status["news_sentiment"] == "unavailable"
    assert "no_source_configured" in report.sections[0].reason
    assert all(
        status[n] == "ok" for n in ("technical", "quantitative", "risk", "portfolio_manager", "verification")
    )
    assert report.verification.passed and report.verification.numbers_checked > 10
    assert any(f.key == "beta" for f in report.facts)
    assert report.interpretation.status == "not_requested"
    assert "Not live prices" in report.freshness and "not investment advice" in report.disclaimer
    assert all(not banned_claims(f) for s in report.sections for f in s.findings)
