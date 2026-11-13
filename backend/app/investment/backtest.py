"""Daily-bar backtest with no look-ahead.

Rules: the strategy decides after bar t closes, seeing only closes[0..t]; the order fills at the
open of bar t + 1 with slippage (buy above, sell below the open, in basis points); charges come from
the cost model; long only, whole shares, all-in / all-out; an open position is marked at the last
close and not sold. Prices are not adjusted for dividends or splits unless the imported bars are.
Money is `Decimal`; the equity curve is converted to floats only for the ratio metrics.
"""

from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from datetime import date
from decimal import ROUND_FLOOR, Decimal

import numpy as np
from pydantic import Field

from app.core.money import round_money
from app.investment import indicators as ind
from app.investment.config import InvestmentConfig
from app.investment.costs import RealisedGain, estimate_tax, order_charges
from app.investment.schemas import NOT_ADVICE, Exchange, Product, Series, Side, TaxEstimate
from app.investment.strategies import Strategy
from app.schemas.common import ZModel

_BPS = Decimal(10_000)


class BacktestTrade(ZModel):
    day: date
    side: Side
    quantity: int
    price: Decimal
    charges: Decimal
    signal_day: date


class BacktestMetrics(ZModel):
    cagr_percent: float | None
    sharpe: float | None
    sortino: float | None
    max_drawdown_percent: float
    volatility_percent: float | None
    win_rate_percent: float | None
    round_trips: int
    turnover: float
    exposure_percent: float


class EquityPoint(ZModel):
    day: date
    equity: Decimal


class BacktestResult(ZModel):
    symbol: str
    exchange: Exchange
    strategy: str
    params: dict[str, int | float]
    start: date
    end: date
    bars: int
    initial_capital: Decimal
    final_equity: Decimal
    total_return_percent: Decimal
    total_costs: Decimal
    slippage_bps: Decimal
    product: Product
    trades: list[BacktestTrade]
    open_quantity: int
    metrics: BacktestMetrics
    tax_estimate: TaxEstimate
    data_source: str
    charges_source: str
    charges_verified_on: str
    assumptions: list[str]
    fingerprint: str
    equity_curve: list[EquityPoint] = Field(default_factory=list)
    disclaimer: str = NOT_ADVICE


def _financial_year(day: date) -> int:
    return day.year if day.month >= 4 else day.year - 1


def run_backtest(
    series: Series,
    strategy: Strategy,
    cfg: InvestmentConfig,
    *,
    initial_capital: Decimal,
    slippage_bps: Decimal = Decimal(5),
    product: Product = "delivery",
    include_curve: bool = False,
) -> BacktestResult:
    candles = series.candles
    if len(candles) < 2:
        raise ValueError("a backtest needs at least two bars")
    if initial_capital <= 0 or slippage_bps < 0:
        raise ValueError("capital must be positive and slippage not negative")
    exchange = series.instrument.exchange
    closes = ind.as_array([c.close for c in candles])
    cash = initial_capital
    qty = 0
    pending: tuple[Side, date] | None = None
    trades: list[BacktestTrade] = []
    gains: list[RealisedGain] = []
    entry_cost = Decimal(0)
    entry_day: date | None = None
    equity: list[Decimal] = []
    traded_value = Decimal(0)
    holding_days = 0

    for t, bar in enumerate(candles):
        if pending is not None:
            side, signal_day = pending
            pending = None
            if side == "buy":
                price = round_money(bar.open * (1 + slippage_bps / _BPS))
                size = _affordable(cfg, cash, price, product, exchange)
                if size > 0:
                    fee = order_charges(
                        cfg.charges, side="buy", quantity=size, price=price, product=product,
                        exchange=exchange,
                    ).total  # fmt: skip
                    cash -= size * price + fee
                    qty, entry_cost, entry_day = size, size * price + fee, bar.day
                    traded_value += size * price
                    trades.append(BacktestTrade(day=bar.day, side="buy", quantity=size, price=price,
                                                charges=fee, signal_day=signal_day))  # fmt: skip
            elif qty > 0:
                price = round_money(bar.open * (1 - slippage_bps / _BPS))
                fee = order_charges(
                    cfg.charges, side="sell", quantity=qty, price=price, product=product, exchange=exchange
                ).total
                proceeds = qty * price - fee
                cash += proceeds
                traded_value += qty * price
                assert entry_day is not None
                gains.append(RealisedGain(entry_day, bar.day, proceeds - entry_cost))
                trades.append(BacktestTrade(day=bar.day, side="sell", quantity=qty, price=price,
                                            charges=fee, signal_day=signal_day))  # fmt: skip
                qty = 0
        if qty > 0:
            holding_days += 1
        equity.append(cash + qty * bar.close)
        if t + 1 < len(candles):
            # The strategy gets a copy of the past only: it cannot read or alter later bars.
            want = strategy.decide(closes[: t + 1].copy(), qty > 0)
            if want and qty == 0:
                pending = ("buy", bar.day)
            elif not want and qty > 0:
                pending = ("sell", bar.day)

    total_costs = sum((tr.charges for tr in trades), Decimal(0))
    final = equity[-1]
    metrics = _metrics(cfg, candles[0].day, candles[-1].day, equity, gains, traded_value, holding_days)
    tax = _tax_by_year(cfg, gains)
    curve = [EquityPoint(day=c.day, equity=round_money(e)) for c, e in zip(candles, equity, strict=True)]
    fingerprint = hashlib.sha256(
        json.dumps(
            {"trades": [t.model_dump(mode="json") for t in trades],
             "equity": [str(round_money(e)) for e in equity]},
            sort_keys=True,
        ).encode()
    ).hexdigest()  # fmt: skip
    return BacktestResult(
        symbol=series.instrument.symbol,
        exchange=exchange,
        strategy=strategy.name,
        params=strategy.params,
        start=candles[0].day,
        end=candles[-1].day,
        bars=len(candles),
        initial_capital=round_money(initial_capital),
        final_equity=round_money(final),
        total_return_percent=round_money((final / initial_capital - 1) * 100),
        total_costs=round_money(total_costs),
        slippage_bps=slippage_bps,
        product=product,
        trades=trades,
        open_quantity=qty,
        metrics=metrics,
        tax_estimate=tax,
        data_source=series.source,
        charges_source=cfg.charges.source,
        charges_verified_on=cfg.charges.verified_on,
        assumptions=[
            "Signal on the close, fill at the next open (no look-ahead).",
            f"Slippage {slippage_bps} basis points against you on every fill.",
            f"Charges from {cfg.charges.source}, checked {cfg.charges.verified_on}.",
            "Long only, whole shares, all-in and all-out; an open position is marked at the last close.",
            "Dividends, splits and corporate actions are not adjusted unless the imported bars are.",
            "Tax is an estimate; see tax_estimate.basis.",
        ],
        fingerprint=fingerprint,
        equity_curve=curve if include_curve else [],
    )


def _affordable(
    cfg: InvestmentConfig, cash: Decimal, price: Decimal, product: Product, exchange: Exchange
) -> int:
    size = int((cash / price).to_integral_value(rounding=ROUND_FLOOR))
    while size > 0:
        fee = order_charges(cfg.charges, side="buy", quantity=size, price=price, product=product,
                            exchange=exchange).total  # fmt: skip
        if size * price + fee <= cash:
            return size
        # step down by roughly the shares the charges cost, at least one
        size -= max(1, int((size * price + fee - cash) / price))
    return 0


def _metrics(
    cfg: InvestmentConfig,
    start: date,
    end: date,
    equity: list[Decimal],
    gains: list[RealisedGain],
    traded_value: Decimal,
    holding_days: int,
) -> BacktestMetrics:
    a = cfg.analytics
    curve = ind.as_array(equity)
    rets = ind.simple_returns(curve)
    years = (end - start).days / 365.25
    cagr = (float(curve[-1] / curve[0]) ** (1 / years) - 1) * 100 if years > 0 and curve[-1] > 0 else None
    rf_daily = float(a.risk_free_rate_percent) / 100 / a.trading_days_per_year
    excess = rets - rf_daily
    root = float(np.sqrt(a.trading_days_per_year))
    sharpe = sortino = vol = None
    if rets.size >= 2:
        sd = float(np.std(excess, ddof=1))
        sharpe = round(float(np.mean(excess)) / sd * root, 4) if sd > 0 else None
        downside = float(np.sqrt(np.mean(np.minimum(excess, 0.0) ** 2)))
        sortino = round(float(np.mean(excess)) / downside * root, 4) if downside > 0 else None
        vol = round(ind.volatility(rets, a.trading_days_per_year) * 100, 4)
    wins = sum(1 for g in gains if g.gain > 0)
    return BacktestMetrics(
        cagr_percent=None if cagr is None else round(cagr, 4),
        sharpe=sharpe,
        sortino=sortino,
        max_drawdown_percent=round(ind.max_drawdown(curve).max_drawdown * 100, 4),
        volatility_percent=vol,
        win_rate_percent=round(wins / len(gains) * 100, 4) if gains else None,
        round_trips=len(gains),
        turnover=round(float(traded_value) / float(np.mean(curve)), 4),
        exposure_percent=round(holding_days / len(equity) * 100, 4),
    )


def _tax_by_year(cfg: InvestmentConfig, gains: list[RealisedGain]) -> TaxEstimate:
    by_year: dict[int, list[RealisedGain]] = defaultdict(list)
    for gain in gains:
        by_year[_financial_year(gain.sold_on)].append(gain)
    parts = [estimate_tax(cfg.tax, items) for _, items in sorted(by_year.items())]
    if not parts:
        return estimate_tax(cfg.tax, [])
    return TaxEstimate(
        short_term_gain=sum((p.short_term_gain for p in parts), Decimal(0)),
        long_term_gain=sum((p.long_term_gain for p in parts), Decimal(0)),
        stcg_tax=sum((p.stcg_tax for p in parts), Decimal(0)),
        ltcg_tax=sum((p.ltcg_tax for p in parts), Decimal(0)),
        total_tax=sum((p.total_tax for p in parts), Decimal(0)),
        basis=parts[0].basis + " Computed per financial year (April to March).",
    )
