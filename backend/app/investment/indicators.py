"""Deterministic technical and risk indicators on numpy float64 arrays (oldest value first).

Conventions (each is tested against hand-computed values in tests/investment/test_indicators.py):
- Output arrays have the input's length; positions without enough history are NaN.
- SMA: plain mean of the last `n` values.
- EMA: alpha = 2 / (n + 1), seeded with the SMA of the first `n` values.
- RSI: Wilder. First average gain / loss = simple mean of the first `n` changes, then
  avg = (prev * (n - 1) + current) / n. RSI = 100 when the average loss is 0.
- MACD: EMA(fast) - EMA(slow); signal = EMA(signal) of the MACD line from its first valid value.
- Bollinger: SMA(n) +- k * population standard deviation (ddof = 0) of the same window.
- ATR: Wilder. True range from the second bar; first ATR = mean of the first `n` true ranges.
- OBV: starts at 0; adds the volume on an up close, subtracts it on a down close.
- Z-scores use a trailing window that excludes the current bar (no look-ahead), sample std (ddof=1).
- Volatility: sample std (ddof=1) of simple returns times sqrt(periods per year).
- Historical VaR: minus the (1 - confidence) quantile of returns, numpy linear interpolation.
These numbers are analytics, not money; money stays `Decimal` elsewhere.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal

import numpy as np
from numpy.typing import NDArray

Array = NDArray[np.float64]


def as_array(values: Sequence[Decimal | int | float] | Array) -> Array:
    return np.asarray([float(v) for v in values], dtype=np.float64)


def simple_returns(close: Array) -> Array:
    """r[t] = close[t] / close[t-1] - 1, length n - 1."""
    if close.size < 2:
        return np.empty(0, dtype=np.float64)
    return close[1:] / close[:-1] - 1.0


def log_returns(close: Array) -> Array:
    if close.size < 2:
        return np.empty(0, dtype=np.float64)
    return np.log(close[1:] / close[:-1])


def sma(values: Array, n: int) -> Array:
    _check_period(n)
    out = np.full(values.size, np.nan)
    if values.size >= n:
        csum = np.cumsum(np.insert(values, 0, 0.0))
        out[n - 1 :] = (csum[n:] - csum[:-n]) / n
    return out


def ema(values: Array, n: int) -> Array:
    _check_period(n)
    out = np.full(values.size, np.nan)
    finite = np.flatnonzero(~np.isnan(values))
    if finite.size == 0:
        return out
    start = int(finite[0])
    if values.size - start < n:
        return out
    alpha = 2.0 / (n + 1)
    seed_at = start + n - 1
    out[seed_at] = float(np.mean(values[start : seed_at + 1]))
    for i in range(seed_at + 1, values.size):
        out[i] = alpha * values[i] + (1 - alpha) * out[i - 1]
    return out


def rsi(close: Array, n: int = 14) -> Array:
    _check_period(n)
    out = np.full(close.size, np.nan)
    if close.size <= n:
        return out
    change = np.diff(close)
    gain = np.where(change > 0, change, 0.0)
    loss = np.where(change < 0, -change, 0.0)
    avg_gain = float(np.mean(gain[:n]))
    avg_loss = float(np.mean(loss[:n]))
    out[n] = _rsi_value(avg_gain, avg_loss)
    for i in range(n + 1, close.size):
        avg_gain = (avg_gain * (n - 1) + gain[i - 1]) / n
        avg_loss = (avg_loss * (n - 1) + loss[i - 1]) / n
        out[i] = _rsi_value(avg_gain, avg_loss)
    return out


def _rsi_value(avg_gain: float, avg_loss: float) -> float:
    if avg_loss == 0:
        return 100.0 if avg_gain > 0 else 50.0
    return 100.0 - 100.0 / (1.0 + avg_gain / avg_loss)


@dataclass(frozen=True)
class Macd:
    line: Array
    signal: Array
    histogram: Array


def macd(close: Array, fast: int = 12, slow: int = 26, signal: int = 9) -> Macd:
    if fast >= slow:
        raise ValueError("fast period must be shorter than slow period")
    line = ema(close, fast) - ema(close, slow)
    sig = ema(line, signal)
    return Macd(line=line, signal=sig, histogram=line - sig)


@dataclass(frozen=True)
class Bands:
    middle: Array
    upper: Array
    lower: Array


def bollinger(close: Array, n: int = 20, k: float = 2.0) -> Bands:
    middle = sma(close, n)
    std = np.full(close.size, np.nan)
    for i in range(n - 1, close.size):
        std[i] = float(np.std(close[i - n + 1 : i + 1], ddof=0))
    return Bands(middle=middle, upper=middle + k * std, lower=middle - k * std)


def true_range(high: Array, low: Array, close: Array) -> Array:
    """TR[0] is NaN (no previous close)."""
    out = np.full(close.size, np.nan)
    if close.size >= 2:
        prev = close[:-1]
        out[1:] = np.maximum.reduce([high[1:] - low[1:], np.abs(high[1:] - prev), np.abs(low[1:] - prev)])
    return out


def atr(high: Array, low: Array, close: Array, n: int = 14) -> Array:
    _check_period(n)
    tr = true_range(high, low, close)
    out = np.full(close.size, np.nan)
    if close.size <= n:
        return out
    out[n] = float(np.mean(tr[1 : n + 1]))
    for i in range(n + 1, close.size):
        out[i] = (out[i - 1] * (n - 1) + tr[i]) / n
    return out


def obv(close: Array, volume: Array) -> Array:
    out = np.zeros(close.size)
    for i in range(1, close.size):
        step = volume[i] if close[i] > close[i - 1] else -volume[i] if close[i] < close[i - 1] else 0.0
        out[i] = out[i - 1] + step
    return out


def trailing_zscore(values: Array, window: int) -> Array:
    """z[t] = (x[t] - mean(x[t-w:t])) / std(x[t-w:t], ddof=1); NaN when undefined."""
    if window < 2:
        raise ValueError("window must be at least 2")
    out = np.full(values.size, np.nan)
    for i in range(window, values.size):
        past = values[i - window : i]
        sd = float(np.std(past, ddof=1))
        if sd > 0:
            out[i] = (values[i] - float(np.mean(past))) / sd
    return out


def volatility(returns: Array, periods_per_year: int = 252) -> float:
    if returns.size < 2:
        return float("nan")
    return float(np.std(returns, ddof=1) * np.sqrt(periods_per_year))


@dataclass(frozen=True)
class Drawdown:
    max_drawdown: float  # positive fraction, e.g. 0.25 for -25 %
    peak_index: int
    trough_index: int


def max_drawdown(equity: Array) -> Drawdown:
    if equity.size == 0:
        return Drawdown(0.0, 0, 0)
    peaks = np.maximum.accumulate(equity)
    drawdowns = equity / peaks - 1.0
    trough = int(np.argmin(drawdowns))
    peak = int(np.argmax(equity[: trough + 1]))
    return Drawdown(max_drawdown=float(-drawdowns[trough]), peak_index=peak, trough_index=trough)


def beta(asset_returns: Array, benchmark_returns: Array) -> float:
    if asset_returns.size != benchmark_returns.size or asset_returns.size < 2:
        raise ValueError("beta needs two equal-length return series of at least 2 values")
    var = float(np.var(benchmark_returns, ddof=1))
    if var == 0:
        return float("nan")
    cov = float(np.cov(asset_returns, benchmark_returns, ddof=1)[0, 1])
    return cov / var


def historical_var(returns: Array, confidence: float = 0.95) -> float:
    """Loss not exceeded with `confidence`, as a positive fraction of value."""
    if not 0 < confidence < 1:
        raise ValueError("confidence must be between 0 and 1")
    if returns.size == 0:
        return float("nan")
    return float(-np.quantile(returns, 1.0 - confidence))


def last(values: Array) -> float | None:
    """The last value, or None when it is NaN (or the array is empty)."""
    if values.size == 0 or np.isnan(values[-1]):
        return None
    return float(values[-1])


def _check_period(n: int) -> None:
    if n < 1:
        raise ValueError("period must be at least 1")
