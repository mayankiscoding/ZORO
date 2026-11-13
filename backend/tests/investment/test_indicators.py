"""Indicators against values computed by hand (worked in the comments)."""

from __future__ import annotations

import math

import numpy as np
import pytest

from app.investment import indicators as ind
from app.investment.config import AnalyticsConfig
from app.investment.movements import detect_unusual, technical_snapshot
from tests.investment.samples import random_walk, series_from_closes


def arr(*values: float) -> ind.Array:
    return np.asarray(values, dtype=np.float64)


def test_returns_sma_ema() -> None:
    assert ind.simple_returns(arr(100, 110, 99)).tolist() == pytest.approx([0.10, -0.10])
    out = ind.sma(arr(1, 2, 3, 4, 5), 3)
    assert math.isnan(out[0]) and math.isnan(out[1]) and out[2:].tolist() == [2, 3, 4]
    # alpha = 2/(3+1) = 0.5, seed = mean(2,4,6) = 4; 0.5*8+0.5*4 = 6; 0.5*10+0.5*6 = 8; 0.5*6+0.5*8 = 7
    assert ind.ema(arr(2, 4, 6, 8, 10, 6), 3)[2:].tolist() == [4, 6, 8, 7]


def test_rsi_wilder_by_hand() -> None:
    # changes 1,-1,2,1,-1. First avg gain (1+0+2)/3 = 1, loss 1/3 -> RS 3 -> 75.
    # next: gain (1*2+1)/3 = 1, loss (2/9) -> RS 4.5 -> 81.818; then gain 2/3, loss 13/27 -> 58.065
    out = ind.rsi(arr(10, 11, 10, 12, 13, 12), 3)
    assert all(math.isnan(v) for v in out[:3])
    assert out[3:].tolist() == pytest.approx([75.0, 100 - 100 / 5.5, 100 - 1300 / 31])
    assert ind.rsi(arr(1, 2, 3, 4), 3)[3] == 100.0  # no losses


def test_macd_by_hand() -> None:
    # ema2 (alpha 2/3): -,2,2,4,4,16/3 ; ema3 (alpha 1/2): -,-,2,3.5,3.75,4.875
    # line: 0, .5, .25, .458333 ; signal ema2 seeded at mean(0,.5)=.25 -> .25, .25, .388889
    m = ind.macd(arr(1, 3, 2, 5, 4, 6), fast=2, slow=3, signal=2)
    assert m.line[2:].tolist() == pytest.approx([0.0, 0.5, 0.25, 16 / 3 - 4.875])
    assert m.signal[5] == pytest.approx(2 / 3 * (16 / 3 - 4.875) + 1 / 3 * 0.25)
    assert m.histogram[5] == pytest.approx((16 / 3 - 4.875) - m.signal[5])
    with pytest.raises(ValueError):
        ind.macd(arr(1, 2), fast=5, slow=3)


def test_bollinger_atr_obv() -> None:
    bands = ind.bollinger(arr(1, 2, 3), 3, 2.0)
    assert bands.middle[2] == 2 and bands.upper[2] == pytest.approx(2 + 2 * math.sqrt(2 / 3))
    assert bands.lower[2] == pytest.approx(2 - 2 * math.sqrt(2 / 3))
    # TR: 1.5, 2, 2 -> ATR(2) at index 2 = 1.75, then (1.75*1 + 2)/2 = 1.875
    a = ind.atr(arr(10, 11, 12, 11), arr(9, 10, 10, 9), arr(9.5, 10.5, 11, 10), 2)
    assert a[2:].tolist() == pytest.approx([1.75, 1.875])
    assert ind.obv(arr(10, 11, 10, 10, 12), arr(100, 200, 300, 400, 500)).tolist() == [
        0,
        200,
        -100,
        -100,
        400,
    ]


def test_risk_measures_by_hand() -> None:
    # returns .01,-.01,.02: sample var 2.3333e-4 -> std .0152753 -> * sqrt(252)
    assert ind.volatility(arr(0.01, -0.01, 0.02)) == pytest.approx(
        math.sqrt(4.6667e-4 / 2) * math.sqrt(252), rel=1e-4
    )
    dd = ind.max_drawdown(arr(100, 120, 90, 130, 65))
    assert (dd.max_drawdown, dd.peak_index, dd.trough_index) == (0.5, 3, 4)
    # cov = .0007/3, var = .0005/3 -> 1.4
    assert ind.beta(arr(0.02, -0.01, 0.03, 0.0), arr(0.01, -0.01, 0.02, 0.0)) == pytest.approx(1.4)
    # 20th percentile, linear: position 0.8 between -.05 and -.02 -> -.026
    assert ind.historical_var(arr(-0.05, -0.02, 0.01, 0.03, 0.04), 0.8) == pytest.approx(0.026)
    z = ind.trailing_zscore(arr(1, 2, 3, 10), 3)
    assert math.isnan(z[2]) and z[3] == pytest.approx(8.0)  # (10 - 2) / 1, current bar excluded


def test_unusual_movement_detection_on_synthetic_series() -> None:
    cfg = AnalyticsConfig()
    calm = [str(100 + (i % 3) * 0.5) for i in range(40)]
    quiet = series_from_closes(calm)
    assert detect_unusual(quiet, cfg) == []

    spike = series_from_closes(
        [*calm, "108.50"], volumes=[100_000 + (i % 4) * 1000 for i in range(40)] + [900_000]
    )
    found = detect_unusual(spike, cfg)
    assert len(found) == 1
    move = found[0]
    assert move.reasons == ["price_up", "volume_spike"] and move.day == spike.candles[-1].day
    assert calm[-1] == "100.0" and move.return_percent == 8.5  # 108.50 / 100.00 - 1
    assert move.return_z is not None and move.return_z > 2.5

    drop = series_from_closes([*calm, "92.00"])
    assert detect_unusual(drop, cfg)[0].reasons == ["price_down"]
    assert detect_unusual(series_from_closes(calm[:10]), cfg) == []  # too short: nothing invented


def test_technical_snapshot_is_deterministic() -> None:
    series = random_walk(120)
    first = technical_snapshot(series, AnalyticsConfig())
    assert first == technical_snapshot(series, AnalyticsConfig())
    assert first.bars == 120 and first.close == series.candles[-1].close
    assert first.rsi_14 is not None and 0 <= first.rsi_14 <= 100
    assert first.sma_50 == pytest.approx(
        float(np.mean([float(c.close) for c in series.candles[-50:]])), abs=0.01
    )
