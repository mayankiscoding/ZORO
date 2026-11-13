"""Synthetic sample data for investment tests only (never shipped)."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date, timedelta
from decimal import Decimal

import numpy as np

from app.investment.schemas import Candle, Instrument, Series
from tests.investment.conftest import NOW

START = date(2025, 1, 1)


def weekdays(n: int, start: date = START) -> list[date]:
    days: list[date] = []
    day = start
    while len(days) < n:
        if day.weekday() < 5:
            days.append(day)
        day += timedelta(days=1)
    return days


def series_from_closes(
    closes: Sequence[str | Decimal], symbol: str = "TESTCO", volumes: list[int] | None = None
) -> Series:
    """Bars whose open equals the previous close (first open = first close)."""
    values = [Decimal(c) for c in closes]
    vols = volumes or [100_000] * len(values)
    candles = []
    for i, (day, close) in enumerate(zip(weekdays(len(values)), values, strict=True)):
        open_ = values[i - 1] if i else close
        candles.append(
            Candle(
                day=day,
                open=open_,
                high=max(open_, close) + 1,
                low=min(open_, close) - 1,
                close=close,
                volume=vols[i],
            )
        )
    return Series(instrument=Instrument(symbol=symbol), candles=candles, source="test", fetched_at=NOW)


def random_walk(n: int = 300, seed: int = 7, symbol: str = "WALK", start_price: float = 1000.0) -> Series:
    rng = np.random.default_rng(seed)
    rets = rng.normal(0.0004, 0.015, n)
    closes = start_price * np.cumprod(1 + rets)
    prices = [Decimal(str(round(float(c), 2))) for c in closes]
    vols = [int(v) for v in rng.integers(50_000, 150_000, n)]
    return series_from_closes(prices, symbol=symbol, volumes=vols)


def bars_csv(series: Series) -> str:
    lines = ["Date,Open,High,Low,Close,Volume"]
    lines += [f"{c.day.isoformat()},{c.open},{c.high},{c.low},{c.close},{c.volume}" for c in series.candles]
    return "\n".join(lines) + "\n"


HOLDINGS_CSV = """Instrument,Exchange,Qty.,Avg. cost,LTP,Price date
WALK,NSE,10,900.50,,
TESTCO,NSE,5,100,120.00,2026-11-12
"""
