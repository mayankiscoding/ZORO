"""Cost model per charge line, tax estimate, and the backtest engine (no look-ahead, reproducible)."""

from __future__ import annotations

import itertools
from datetime import date
from decimal import Decimal

import pytest

from app.core.errors import ConfigError
from app.investment.backtest import run_backtest
from app.investment.config import InvestmentConfig, parse_config
from app.investment.costs import RealisedGain, estimate_tax, order_charges
from app.investment.strategies import Strategy, build_strategy, buy_and_hold
from tests.investment.samples import random_walk, series_from_closes

D = Decimal


def lines(b: object) -> dict[str, Decimal]:
    keys = ("brokerage", "stt", "exchange_transaction", "sebi_fee", "stamp_duty", "gst", "dp_charge", "total")
    return {k: getattr(b, k) for k in keys}


def test_config_carries_source_and_refuses_floats(cfg: InvestmentConfig) -> None:
    assert cfg.charges.source == "https://zerodha.com/charges" and cfg.charges.verified_on == "2026-11-12"
    assert cfg.charges.delivery.stt_buy_percent == D("0.1") and cfg.tax.ltcg_percent == D("12.5")
    with pytest.raises(ConfigError):
        parse_config("charges: {gst_percent: 18.0}\n")


def test_delivery_charges_per_line(cfg: InvestmentConfig) -> None:
    # 100 x 1000 = 1,00,000 turnover on NSE.
    buy = order_charges(cfg.charges, side="buy", quantity=100, price=D("1000"), product="delivery")
    # STT 0.1% = 100; txn 0.00307% = 3.07; SEBI 10/cr = 0.10; stamp 0.015% = 15; GST 18% of 3.17 = 0.5706
    assert lines(buy) == {"brokerage": D("0.00"), "stt": D("100.00"), "exchange_transaction": D("3.07"),
                          "sebi_fee": D("0.10"), "stamp_duty": D("15.00"), "gst": D("0.57"),
                          "dp_charge": D("0.00"), "total": D("118.74")}  # fmt: skip
    sell = order_charges(cfg.charges, side="sell", quantity=100, price=D("1000"), product="delivery")
    # DP 13.00 per scrip on sell; GST 18% of (3.07 + 0.10 + 13.00) = 2.9106
    assert lines(sell) == {"brokerage": D("0.00"), "stt": D("100.00"), "exchange_transaction": D("3.07"),
                           "sebi_fee": D("0.10"), "stamp_duty": D("0.00"), "gst": D("2.91"),
                           "dp_charge": D("13.00"), "total": D("119.08")}  # fmt: skip
    assert sell.dp_charge + D("0.18") * sell.dp_charge == D("15.34")  # Zerodha's published DP incl. GST


def test_intraday_charges_per_line(cfg: InvestmentConfig) -> None:
    buy = order_charges(cfg.charges, side="buy", quantity=100, price=D("1000"), product="intraday")
    # brokerage min(0.03% = 30, 20) = 20; no STT on buy; stamp 0.003% = 3; GST 18% of 23.17 = 4.1706
    assert lines(buy) == {"brokerage": D("20.00"), "stt": D("0.00"), "exchange_transaction": D("3.07"),
                          "sebi_fee": D("0.10"), "stamp_duty": D("3.00"), "gst": D("4.17"),
                          "dp_charge": D("0.00"), "total": D("30.34")}  # fmt: skip
    sell = order_charges(cfg.charges, side="sell", quantity=100, price=D("1000"), product="intraday")
    assert (sell.stt, sell.stamp_duty, sell.dp_charge, sell.total) == (
        D("25.00"),
        D("0.00"),
        D("0.00"),
        D("52.34"),
    )
    small = order_charges(cfg.charges, side="buy", quantity=10, price=D("100"), product="intraday")
    assert small.brokerage == D("0.30")  # 0.03% is below the Rs 20 cap
    bse = order_charges(cfg.charges, side="buy", quantity=100, price=D("1000"), exchange="BSE")
    assert bse.exchange_transaction == D("3.75")
    with pytest.raises(ValueError):
        order_charges(cfg.charges, side="buy", quantity=0, price=D("1"))


def test_tax_estimate(cfg: InvestmentConfig) -> None:
    gains = [
        RealisedGain(date(2025, 4, 10), date(2025, 9, 1), D("50000")),  # short term
        RealisedGain(date(2024, 1, 1), date(2025, 6, 1), D("200000")),  # long term
    ]
    tax = estimate_tax(cfg.tax, gains)
    assert (tax.stcg_tax, tax.ltcg_tax, tax.total_tax) == (D("10000.00"), D("9375.00"), D("19375.00"))
    assert tax.is_estimate and "Estimate" in tax.basis
    assert (
        estimate_tax(cfg.tax, [RealisedGain(date(2024, 1, 1), date(2025, 6, 1), D("100000"))]).ltcg_tax == 0
    )


def test_buy_and_hold_by_hand(cfg: InvestmentConfig) -> None:
    series = series_from_closes(["100", "120", "125"])  # opens: 100, 100, 120
    series.candles[1].open, series.candles[2].open = D("110"), D("130")
    result = run_backtest(series, buy_and_hold(), cfg, initial_capital=D("10000"), slippage_bps=D("0"))
    # signal on day 1 close, fill day 2 open at 110: 90 shares = 9900 + charges 11.75 (STT 9.90, txn 0.30,
    # SEBI 0.01, stamp 1.48, GST 0.06) -> cash 88.25; equity 88.25 + 90 x 125 = 11338.25
    [trade] = result.trades
    assert (trade.day, trade.quantity, trade.price, trade.charges) == (
        series.candles[1].day,
        90,
        D("110.00"),
        D("11.75"),
    )
    assert trade.signal_day == series.candles[0].day
    assert result.final_equity == D("11338.25") and result.open_quantity == 90
    assert result.total_costs == D("11.75") and result.total_return_percent == D("13.38")
    slipped = run_backtest(series, buy_and_hold(), cfg, initial_capital=D("10000"), slippage_bps=D("10"))
    assert slipped.trades[0].price == D("110.11")  # 10 bps above the open


def test_no_look_ahead(cfg: InvestmentConfig) -> None:
    seen: list[int] = []

    def spy(closes: object, holding: bool) -> bool:
        seen.append(len(closes))  # type: ignore[arg-type]
        return len(seen) % 7 < 4

    series = random_walk(60)
    result = run_backtest(series, Strategy("momentum", {}, spy, 1), cfg, initial_capital=D("100000"))
    assert seen == list(range(1, 60))  # decision t saw exactly bars 0..t, never the last bar's future
    for trade in result.trades:
        index = [c.day for c in series.candles].index(trade.day)
        assert series.candles[index - 1].day == trade.signal_day  # filled at the next bar's open

    # Changing the future does not change any trade decided before it.
    base = run_backtest(
        series, build_strategy("sma_crossover", {"fast": 5, "slow": 20}), cfg, initial_capital=D("100000")
    )
    future = series.model_copy(deep=True)
    for candle in future.candles[45:]:
        candle.close = candle.close * 3
        candle.high = candle.high * 3
    changed = run_backtest(
        future, build_strategy("sma_crossover", {"fast": 5, "slow": 20}), cfg, initial_capital=D("100000")
    )
    cutoff = series.candles[45].day
    assert [t for t in base.trades if t.day <= cutoff] == [t for t in changed.trades if t.day <= cutoff]


@pytest.mark.parametrize("name", ["buy_and_hold", "sma_crossover", "rsi_mean_reversion", "momentum"])
def test_backtests_are_reproducible(cfg: InvestmentConfig, name: str) -> None:
    series = random_walk(400, seed=11)
    params = {"lookback": 20} if name == "momentum" else {}
    one = run_backtest(series, build_strategy(name, params), cfg, initial_capital=D("500000"))  # type: ignore[arg-type]
    two = run_backtest(series, build_strategy(name, params), cfg, initial_capital=D("500000"))  # type: ignore[arg-type]
    assert one == two and one.fingerprint == two.fingerprint
    m = one.metrics
    assert m.max_drawdown_percent >= 0 and 0 <= m.exposure_percent <= 100
    assert one.total_costs == sum((t.charges for t in one.trades), D(0))
    sides = [t.side for t in one.trades]
    assert all(a != b for a, b in itertools.pairwise(sides))  # alternating buy / sell, long only
    if m.round_trips:
        assert m.win_rate_percent is not None and 0 <= m.win_rate_percent <= 100
    assert one.tax_estimate.is_estimate and "next open" in one.assumptions[0]


def test_backtest_rejects_bad_input(cfg: InvestmentConfig) -> None:
    with pytest.raises(ValueError):
        run_backtest(series_from_closes(["100"]), buy_and_hold(), cfg, initial_capital=D("1000"))
    with pytest.raises(ValueError):
        build_strategy("sma_crossover", {"fast": 50, "slow": 20})
