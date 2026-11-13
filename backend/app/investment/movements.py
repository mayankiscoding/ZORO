"""Unusual-movement detection and the technical snapshot, computed from stored daily bars.

A bar is unusual when its return z-score or its volume z-score against the trailing window
(current bar excluded) reaches the thresholds in `config/india_charges.yaml: analytics`.
"""

from __future__ import annotations

from decimal import Decimal

import numpy as np

from app.investment import indicators as ind
from app.investment.config import AnalyticsConfig
from app.investment.schemas import Series, TechnicalSnapshot, UnusualMovement


def _round(value: float | None, places: int = 2) -> float | None:
    return None if value is None else round(value, places)


def detect_unusual(series: Series, cfg: AnalyticsConfig, *, lookback_bars: int = 1) -> list[UnusualMovement]:
    """Unusual bars among the last `lookback_bars` of the series (most recent first)."""
    candles = series.candles
    window = cfg.unusual_window
    if len(candles) < window + 2:
        return []
    close = ind.as_array([c.close for c in candles])
    volume = ind.as_array([c.volume for c in candles])
    returns = ind.simple_returns(close)  # returns[i] belongs to bar i + 1
    ret_z = ind.trailing_zscore(returns, window)
    vol_z = ind.trailing_zscore(volume, window)
    ret_threshold = float(cfg.unusual_return_z)
    vol_threshold = float(cfg.unusual_volume_z)
    found: list[UnusualMovement] = []
    for bar in range(len(candles) - 1, max(len(candles) - 1 - lookback_bars, 0), -1):
        rz = ret_z[bar - 1]
        vz = vol_z[bar]
        reasons: list[str] = []
        if not np.isnan(rz) and abs(rz) >= ret_threshold:
            reasons.append("price_up" if rz > 0 else "price_down")
        if not np.isnan(vz) and vz >= vol_threshold:
            reasons.append("volume_spike")
        if reasons:
            candle = candles[bar]
            found.append(
                UnusualMovement(
                    symbol=series.instrument.symbol,
                    exchange=series.instrument.exchange,
                    day=candle.day,
                    close=candle.close,
                    return_percent=round(float(returns[bar - 1]) * 100, 2),
                    return_z=None if np.isnan(rz) else round(float(rz), 2),
                    volume=candle.volume,
                    volume_z=None if np.isnan(vz) else round(float(vz), 2),
                    reasons=reasons,
                    source=series.source,
                )
            )
    return found


def technical_snapshot(series: Series, cfg: AnalyticsConfig) -> TechnicalSnapshot:
    candles = series.candles
    if not candles:
        raise ValueError("no bars")
    close = ind.as_array([c.close for c in candles])
    high = ind.as_array([c.high for c in candles])
    low = ind.as_array([c.low for c in candles])
    volume = ind.as_array([c.volume for c in candles])
    macd = ind.macd(close)
    bands = ind.bollinger(close)
    return TechnicalSnapshot(
        symbol=series.instrument.symbol,
        exchange=series.instrument.exchange,
        as_of=candles[-1].day,
        source=series.source,
        bars=len(candles),
        close=candles[-1].close,
        sma_20=_round(ind.last(ind.sma(close, 20))),
        sma_50=_round(ind.last(ind.sma(close, 50))),
        ema_20=_round(ind.last(ind.ema(close, 20))),
        rsi_14=_round(ind.last(ind.rsi(close, 14)), 1),
        macd=_round(ind.last(macd.line)),
        macd_signal=_round(ind.last(macd.signal)),
        macd_histogram=_round(ind.last(macd.histogram)),
        bollinger_upper=_round(ind.last(bands.upper)),
        bollinger_lower=_round(ind.last(bands.lower)),
        atr_14=_round(ind.last(ind.atr(high, low, close, 14))),
        obv=_round(ind.last(ind.obv(close, volume)), 0),
        volume_z=_round(ind.last(ind.trailing_zscore(volume, cfg.unusual_window))),
    )


def decimal_or_none(value: float | None, places: int = 2) -> Decimal | None:
    if value is None or not np.isfinite(value):
        return None
    return Decimal(str(round(value, places)))
