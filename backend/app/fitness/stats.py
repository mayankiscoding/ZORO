"""Small, exact statistics in plain code. Every function refuses (returns None) when there is too
little data, so callers can say "not enough data" instead of showing a made-up trend."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date, timedelta

MIN_TREND_POINTS = 7
MIN_WINDOW_DAYS = 3  # days with data needed in each week of a week-over-week comparison
FLAT_BAND = 0.05  # a window change smaller than 5% of the mean counts as steady


def mean(values: Sequence[float]) -> float | None:
    return sum(values) / len(values) if values else None


def slope(xs: Sequence[float], ys: Sequence[float], *, min_points: int = MIN_TREND_POINTS) -> float | None:
    """Least-squares slope of y on x (units of y per unit of x). None with fewer than `min_points`
    points or when all x are equal."""
    n = len(xs)
    if n != len(ys) or n < max(min_points, 2):
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys, strict=True)) / sxx


def direction(slope_per_unit: float, span: float, level: float) -> str:
    """ "up" / "down" / "steady": the change across `span` units against `level` (the mean)."""
    change = slope_per_unit * span
    if level == 0:
        return "steady" if change == 0 else ("up" if change > 0 else "down")
    if abs(change) < FLAT_BAND * abs(level):
        return "steady"
    return "up" if change > 0 else "down"


def pct_change(current: float | None, previous: float | None) -> float | None:
    if current is None or previous is None or previous == 0:
        return None
    return (current - previous) / previous * 100.0


def streak_ending(active: set[date], end: date) -> int:
    """Consecutive active days ending at `end`; if `end` itself is not active yet the day is not
    over, so the count starts from the day before."""
    day = end if end in active else end - timedelta(days=1)
    count = 0
    while day in active:
        count += 1
        day -= timedelta(days=1)
    return count


def longest_streak(active: set[date]) -> int:
    best = run = 0
    previous: date | None = None
    for d in sorted(active):
        run = run + 1 if previous is not None and d - previous == timedelta(days=1) else 1
        best = max(best, run)
        previous = d
    return best


def week_start(d: date) -> date:
    return d - timedelta(days=d.weekday())  # Monday


def pace_text(seconds_per_km: float | None) -> str | None:
    """ "6:24" for 384 seconds per kilometre."""
    if seconds_per_km is None:
        return None
    total = int(seconds_per_km + 0.5)
    return f"{total // 60}:{total % 60:02d}"
