"""Synthetic fitness series (test data only)."""

from __future__ import annotations

from datetime import date, timedelta
from typing import Any

TODAY = date(2026, 11, 13)
GENERATED = "2026-11-13T12:00:00+05:30"


def day(d: date, **fields: Any) -> dict[str, Any]:
    base: dict[str, Any] = {"date": d.isoformat(), "sources": ["Apple Watch", "iPhone"]}
    base.update(fields)
    return base


def series(n: int, *, end: date = TODAY, **fn: Any) -> list[dict[str, Any]]:
    """`n` consecutive days ending at `end`; each keyword is a function of the index 0..n-1 (oldest first)."""
    out = []
    for i in range(n):
        d = end - timedelta(days=n - 1 - i)
        out.append(day(d, **{k: (v(i) if callable(v) else v) for k, v in fn.items()}))
    return out


def run(
    wid: str, d: date, km: float, pace: float | None, *, hr: float | None = 150, hour: int = 6
) -> dict[str, Any]:
    start = f"{d.isoformat()}T{hour:02d}:10:00+05:30"
    duration = None if pace is None else km * pace
    return {
        "id": wid,
        "type": "running",
        "start_at": start,
        "end_at": None,
        "duration_s": duration,
        "distance_m": km * 1000,
        "active_energy_kcal": km * 62,
        "avg_heart_rate_bpm": hr,
        "avg_pace_s_per_km": pace,
        "source": "Apple Watch",
    }


def payload(
    days: list[dict[str, Any]], workouts: list[dict[str, Any]] | None = None, generated: str = GENERATED
) -> dict[str, Any]:
    return {"generated_at": generated, "days": days, "workouts": workouts or []}
