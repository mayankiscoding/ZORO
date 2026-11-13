"""Portfolio maths: valuation, P&L, allocation, concentration (HHI), risk exposure, performance.

Valuation uses, per holding, the most recent of the price stored with the holding and the last
imported daily close, each with its source and time. A holding with no price is listed as
unpriced and left out of the totals: it is never valued at cost or at an invented price.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from decimal import Decimal

import numpy as np

from app.core.money import from_paise, round_money
from app.investment import indicators as ind
from app.investment.config import AnalyticsConfig, InvestmentConfigSource
from app.investment.csv_import import MARKET_CLOSE
from app.investment.schemas import (
    HoldingView,
    Instrument,
    PerformancePoint,
    PerformanceReport,
    PortfolioSummary,
    RiskExposure,
    Series,
)
from app.investment.store import InvestmentStore, StoredHolding

MIN_RISK_BARS = 30
_FOUR = Decimal("0.0001")


def value_holdings(
    holdings: list[StoredHolding], latest: dict[str, tuple[Decimal, datetime, str]]
) -> list[HoldingView]:
    """`latest` maps "EXCH:SYMBOL" to (close, as_of, source) from imported bars."""
    views: list[HoldingView] = []
    for h in holdings:
        key = f"{h.exchange}:{h.symbol}"
        price, as_of, source = h.last_price, h.price_as_of, h.source if h.last_price is not None else None
        bar = latest.get(key)
        if bar is not None and (as_of is None or bar[1] > as_of):
            price, as_of, source = bar
        invested = round_money(h.quantity * h.average_price)
        view = HoldingView(
            symbol=h.symbol, exchange=h.exchange, quantity=h.quantity, average_price=h.average_price,
            invested=invested, source=h.source, last_price=price, price_as_of=as_of, price_source=source,
        )  # fmt: skip
        if price is not None:
            value = round_money(h.quantity * price)
            view.value = value
            view.pnl = value - invested
            view.pnl_percent = round_money(view.pnl / invested * 100) if invested > 0 else None
        views.append(view)
    return views


def concentration(values: list[Decimal]) -> tuple[Decimal | None, Decimal | None]:
    """(HHI on weights 0-1, effective number of holdings 1/HHI)."""
    total = sum(values, Decimal(0))
    if total <= 0:
        return None, None
    hhi = sum(((v / total) ** 2 for v in values), Decimal(0))
    return hhi.quantize(_FOUR), (1 / hhi).quantize(Decimal("0.01"))


def risk_exposure(
    weights: dict[str, Decimal], series: dict[str, Series | None], value: Decimal, cfg: AnalyticsConfig
) -> RiskExposure:
    missing = sorted(k for k in weights if len(_candles(series.get(k))) < MIN_RISK_BARS)
    if not weights:
        return RiskExposure(status="unavailable", reason="no priced holdings")
    if missing:
        return RiskExposure(
            status="unavailable",
            reason=f"needs at least {MIN_RISK_BARS} daily bars for: {', '.join(missing)}",
        )
    closes: dict[str, dict[date, float]] = {
        k: {c.day: float(c.close) for c in s.candles}
        for k, s in series.items()
        if s is not None and k in weights
    }
    common = sorted(set.intersection(*(set(d) for d in closes.values())))
    if len(common) < MIN_RISK_BARS:
        return RiskExposure(status="unavailable", reason="holdings do not share enough trading days")
    port = np.zeros(len(common) - 1)
    for key, w in weights.items():
        arr = np.asarray([closes[key][d] for d in common], dtype=np.float64)
        port += float(w) * ind.simple_returns(arr)
    conf = float(cfg.var_confidence_percent) / 100
    var = ind.historical_var(port, conf)
    return RiskExposure(
        status="ok",
        annual_volatility_percent=round(ind.volatility(port, cfg.trading_days_per_year) * 100, 2),
        var_1d_percent=round(var * 100, 2),
        var_1d_amount=round_money(value * Decimal(str(round(var, 6)))),
        observations=int(port.size),
    )


class PortfolioService:
    def __init__(self, store: InvestmentStore, config: InvestmentConfigSource) -> None:
        self._store = store
        self._config = config

    async def summary(self, now: datetime) -> PortfolioSummary:
        cfg = self._config.current().analytics
        holdings = await self._store.holdings()
        latest: dict[str, tuple[Decimal, datetime, str]] = {}
        series: dict[str, Series | None] = {}
        for h in holdings:
            key = f"{h.exchange}:{h.symbol}"
            s = await self._store.series(Instrument(symbol=h.symbol, exchange=h.exchange), limit=260)
            series[key] = s
            if s is not None:
                bar = s.candles[-1]
                latest[key] = (bar.close, _close_time(bar.day), f"csv:{s.source}")
        views = value_holdings(holdings, latest)
        priced = [v for v in views if v.value is not None]
        value = sum((v.value or Decimal(0) for v in priced), Decimal(0))
        invested = sum((v.invested for v in priced), Decimal(0))
        flags: list[str] = []
        weights: dict[str, Decimal] = {}
        for v in priced:
            if value > 0 and v.value is not None:
                weight = v.value / value
                weights[f"{v.exchange}:{v.symbol}"] = weight
                v.weight_percent = round_money(weight * 100)
                if v.weight_percent > cfg.concentration_single_percent:
                    flags.append(f"{v.symbol} is {v.weight_percent}% of the priced portfolio "
                                 f"(above {cfg.concentration_single_percent}%)")  # fmt: skip
        hhi, effective = concentration([v.value for v in priced if v.value is not None])
        top = max(priced, key=lambda v: v.value or Decimal(0), default=None)
        sources = sorted({v.price_source for v in priced if v.price_source} | {v.source for v in views})
        return PortfolioSummary(
            as_of=now, holdings=views, holdings_count=len(views), priced_count=len(priced),
            invested=round_money(invested), value=round_money(value), pnl=round_money(value - invested),
            pnl_percent=round_money((value - invested) / invested * 100) if invested > 0 else None,
            hhi=hhi, effective_holdings=effective, concentration_flags=flags,
            top_holding=top.symbol if top else None, top_weight_percent=top.weight_percent if top else None,
            risk=risk_exposure(weights, series, value, cfg), sources=sources,
            unpriced=[v.symbol for v in views if v.value is None],
        )  # fmt: skip

    async def snapshot(self, now: datetime) -> PerformancePoint:
        summary = await self.summary(now)
        row = await self._store.add_snapshot(summary.value, summary.invested, summary.priced_count)
        return PerformancePoint(taken_at=row.taken_at, value=summary.value, invested=summary.invested)

    async def performance(self) -> PerformanceReport:
        rows = await self._store.snapshots()
        points = [
            PerformancePoint(
                taken_at=r.taken_at, value=from_paise(r.value_paise), invested=from_paise(r.invested_paise)
            )
            for r in rows
        ]
        if len(points) < 2 or points[0].value == 0:
            return PerformanceReport(points=points)
        change = points[-1].value - points[0].value
        return PerformanceReport(
            points=points, change=change, change_percent=round_money(change / points[0].value * 100)
        )


def _candles(series: Series | None) -> list[object]:
    return [] if series is None else list(series.candles)


def _close_time(day: date) -> datetime:
    return datetime.combine(day, MARKET_CLOSE).astimezone(UTC)
