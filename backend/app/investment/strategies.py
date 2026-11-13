"""Long-only daily strategies. A strategy sees only the closes up to and including today and
answers "should I hold the instrument after today's close?". The engine fills at the next open."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Literal

import numpy as np

from app.investment import indicators as ind

StrategyName = Literal["buy_and_hold", "sma_crossover", "rsi_mean_reversion", "momentum"]

Decide = Callable[[ind.Array, bool], bool]
"""(closes up to today, currently holding) -> hold after today's close."""


@dataclass(frozen=True)
class Strategy:
    name: StrategyName
    params: dict[str, int | float]
    decide: Decide
    warmup: int  # bars needed before the first signal can be true


def buy_and_hold() -> Strategy:
    return Strategy("buy_and_hold", {}, lambda closes, holding: True, warmup=1)


def sma_crossover(fast: int = 20, slow: int = 50) -> Strategy:
    if not 1 <= fast < slow:
        raise ValueError("need 1 <= fast < slow")

    def decide(closes: ind.Array, holding: bool) -> bool:
        if closes.size < slow:
            return False
        return float(np.mean(closes[-fast:])) > float(np.mean(closes[-slow:]))

    return Strategy("sma_crossover", {"fast": fast, "slow": slow}, decide, warmup=slow)


def rsi_mean_reversion(period: int = 14, lower: float = 30, upper: float = 70) -> Strategy:
    if not 0 < lower < upper < 100:
        raise ValueError("need 0 < lower < upper < 100")

    def decide(closes: ind.Array, holding: bool) -> bool:
        value = ind.last(ind.rsi(closes, period))
        if value is None:
            return False
        if not holding:
            return value < lower
        return value <= upper  # keep holding until RSI rises above the upper band

    params: dict[str, int | float] = {"period": period, "lower": lower, "upper": upper}
    return Strategy("rsi_mean_reversion", params, decide, warmup=period + 1)


def momentum(lookback: int = 60) -> Strategy:
    if lookback < 1:
        raise ValueError("lookback must be at least 1")

    def decide(closes: ind.Array, holding: bool) -> bool:
        if closes.size <= lookback:
            return False
        return float(closes[-1] / closes[-1 - lookback]) - 1.0 > 0

    return Strategy("momentum", {"lookback": lookback}, decide, warmup=lookback + 1)


def build_strategy(name: StrategyName, params: Mapping[str, float] | None = None) -> Strategy:
    p = dict(params or {})
    if name == "buy_and_hold":
        return buy_and_hold()
    if name == "sma_crossover":
        return sma_crossover(int(p.get("fast", 20)), int(p.get("slow", 50)))
    if name == "rsi_mean_reversion":
        return rsi_mean_reversion(int(p.get("period", 14)), p.get("lower", 30), p.get("upper", 70))
    if name == "momentum":
        return momentum(int(p.get("lookback", 60)))
    raise ValueError(f"unknown strategy {name}")
