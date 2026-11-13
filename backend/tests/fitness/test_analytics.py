"""Each analytic on synthetic series, and every minimum-data refusal."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

import pytest

from app.fitness import analytics as a
from app.fitness.observations import recovery_observations, render_observation
from app.fitness.records import DayRec, WorkoutRec
from app.fitness.stats import longest_streak, pace_text, pct_change, slope, streak_ending, week_start

TODAY = date(2026, 11, 13)  # a Friday
IST = timezone(timedelta(hours=5, minutes=30))


def days(n: int, end: date = TODAY, **fn: object) -> list[DayRec]:
    out = []
    for i in range(n):
        d = end - timedelta(days=n - 1 - i)
        out.append(DayRec(d, **{k: (v(i) if callable(v) else v) for k, v in fn.items()}))  # type: ignore[arg-type]
    return out


def run(wid: str, d: date, km: float, pace: float | None, origin: str = "healthkit") -> WorkoutRec:
    return WorkoutRec(
        id=wid,
        type="running",
        start_at=datetime(d.year, d.month, d.day, 6, 0, tzinfo=IST),
        local_date=d,
        origin=origin,
        duration_s=None if pace is None else km * pace,
        distance_m=km * 1000,
        avg_pace_s_per_km=pace,
        source="Apple Watch",
    )


# ---------------------------------------------------------------- stats


def test_slope_is_the_least_squares_fit_and_needs_enough_points() -> None:
    xs = [float(i) for i in range(10)]
    assert slope(xs, [3 + 2 * x for x in xs]) == pytest.approx(2.0)
    assert slope(xs, [5.0] * 10) == pytest.approx(0.0)
    assert slope(xs[:6], [1.0] * 6) is None  # below the 7-point minimum
    assert slope([1.0] * 8, [float(i) for i in range(8)]) is None  # all x equal
    assert slope(xs[:4], [1, 2, 3, 4], min_points=4) == pytest.approx(1.0)


def test_pct_change_and_streak_helpers() -> None:
    assert pct_change(110, 100) == pytest.approx(10.0)
    assert pct_change(5, 0) is None and pct_change(None, 3) is None
    active = {TODAY - timedelta(days=i) for i in (1, 2, 3, 6, 7)}
    assert streak_ending(active, TODAY) == 3  # today not active yet: counted from yesterday
    assert streak_ending(active | {TODAY}, TODAY) == 4
    assert longest_streak(active) == 3
    assert week_start(TODAY) == date(2026, 11, 9) and pace_text(384.5) == "6:25" and pace_text(None) is None


# ---------------------------------------------------------------- trends


def test_trend_direction_and_slope_per_week() -> None:
    up = a.trend(days(28, steps=lambda i: 5000 + 100 * i), "steps", TODAY - timedelta(days=27), TODAY)
    assert up.available and up.direction == "up" and up.slope_per_week == pytest.approx(700.0)
    down = a.trend(
        days(28, resting_heart_rate_bpm=lambda i: 70 - 0.2 * i),
        "resting_heart_rate_bpm",
        TODAY - timedelta(days=27),
        TODAY,
    )
    assert down.direction == "down" and down.slope_per_week == pytest.approx(-1.4)
    flat = a.trend(days(28, steps=8000), "steps", TODAY - timedelta(days=27), TODAY)
    assert flat.direction == "steady" and flat.slope_per_week == pytest.approx(0.0)
    noise = a.trend(
        days(28, steps=lambda i: 8000 + (10 if i % 2 else -10)), "steps", TODAY - timedelta(days=27), TODAY
    )
    assert noise.direction == "steady"  # a change under 5% of the mean is not a trend


def test_trend_refuses_below_the_minimum_and_ignores_nulls() -> None:
    few = a.trend(days(6, steps=1000), "steps", TODAY - timedelta(days=5), TODAY)
    assert not few.available and few.reason == "not_enough_data" and few.points_used == 6
    assert few.direction == "insufficient_data" and few.slope_per_week is None
    sparse = days(28, steps=lambda i: 5000 + 10 * i if i % 4 == 0 else None)  # 7 real points
    assert a.trend(sparse, "steps", TODAY - timedelta(days=27), TODAY).available
    assert not a.trend(sparse[:24], "steps", TODAY - timedelta(days=23), TODAY - timedelta(days=4)).available


# ---------------------------------------------------------------- weekly comparison


def test_weekly_comparison_percentages_and_workout_counts() -> None:
    rows = days(14, steps=lambda i: 10000 if i >= 7 else 8000, sleep_minutes=420)
    runs = [
        run("r1", TODAY, 5, 360),
        run("r2", TODAY - timedelta(days=2), 5, 360),
        run("r3", TODAY - timedelta(days=9), 5, 360),
    ]
    result = a.weekly_comparison(rows, runs, TODAY)
    steps = next(m for m in result.metrics if m.metric == "steps")
    assert (
        steps.enough_data
        and steps.current_avg == 10000
        and steps.previous_avg == 8000
        and steps.change_pct == 25.0
    )
    sleep = next(m for m in result.metrics if m.metric == "sleep_hours")
    assert sleep.change_pct == 0.0 and sleep.current_avg == 7.0
    assert (result.workouts_current, result.workouts_previous) == (2, 1)
    assert (result.current_start, result.previous_end) == (date(2026, 11, 7), date(2026, 11, 6))


def test_weekly_comparison_needs_three_days_in_each_week() -> None:
    rows = days(14, steps=lambda i: 9000 if i in (0, 1, 8, 9, 10, 11) else None)  # 2 days in the earlier week
    steps = next(m for m in a.weekly_comparison(rows, [], TODAY).metrics if m.metric == "steps")
    assert (
        not steps.enough_data
        and steps.change_pct is None
        and (steps.days_previous, steps.days_current) == (2, 4)
    )
    empty = a.weekly_comparison([], [], TODAY)
    assert not empty.available and empty.reason == "not_enough_data"


# ---------------------------------------------------------------- running


def test_running_pace_trend_gets_faster() -> None:
    runs = [run(f"r{i}", TODAY - timedelta(days=60 - 6 * i), 5.0, 420.0 - 5 * i) for i in range(10)]
    r = a.running_progress(runs, TODAY - timedelta(days=89), TODAY)
    assert r.available and r.runs == 10 and r.total_km == 50.0 and r.direction == "faster"
    assert r.pace_change_s_per_km_per_week == pytest.approx(-5 / 6 * 7, abs=0.01)
    assert r.avg_pace_text == pace_text(sum(420 - 5 * i for i in range(10)) / 10)
    assert r.recent_pace_text == pace_text((385 + 380 + 375) / 3) and sum(w.runs for w in r.weekly) == 10


def test_running_pace_slower_and_steady() -> None:
    slow = [run(f"s{i}", TODAY - timedelta(days=50 - 7 * i), 5.0, 360.0 + 8 * i) for i in range(6)]
    assert a.running_progress(slow, TODAY - timedelta(days=89), TODAY).direction == "slower"
    steady = [run(f"t{i}", TODAY - timedelta(days=50 - 7 * i), 5.0, 360.0) for i in range(6)]
    assert a.running_progress(steady, TODAY - timedelta(days=89), TODAY).direction == "steady"


def test_running_progress_refusals() -> None:
    none = a.running_progress([], TODAY - timedelta(days=89), TODAY)
    assert not none.available and none.reason == "no_running_data"
    three = [run(f"x{i}", TODAY - timedelta(days=i * 3), 5.0, 360.0) for i in range(3)]
    r = a.running_progress(three, TODAY - timedelta(days=89), TODAY)
    assert (
        r.available
        and r.runs == 3
        and r.direction == "insufficient_data"
        and r.pace_change_s_per_km_per_week is None
    )
    short = [run(f"y{i}", TODAY - timedelta(days=i), 0.5, 360.0) for i in range(6)]  # under 1 km do not count
    assert a.running_progress(short, TODAY - timedelta(days=89), TODAY).reason == "no_running_data"
    no_pace = [run(f"z{i}", TODAY - timedelta(days=i * 3), 5.0, None) for i in range(6)]
    p = a.running_progress(no_pace, TODAY - timedelta(days=89), TODAY)
    assert p.avg_pace_s_per_km is None and p.direction == "insufficient_data"  # no pace is never invented


# ---------------------------------------------------------------- records


def test_personal_records() -> None:
    runs = [
        run("a", date(2026, 11, 1), 5.0, 360.0),
        run("b", date(2026, 11, 5), 10.4, 380.0),
        run("c", date(2026, 11, 9), 2.0, 300.0),
    ]
    rows = [
        DayRec(date(2026, 11, 2), steps=12000, exercise_minutes=50),
        DayRec(date(2026, 11, 3), steps=15000, exercise_minutes=20, sources=("iPhone",)),
    ]
    kinds = {r.kind: r for r in a.personal_records(rows, runs).records}
    assert kinds["longest_run"].display == "10.4" and kinds["longest_run"].workout_id == "b"
    assert (
        kinds["fastest_pace_run"].workout_id == "a"
    )  # the 2 km run is under the 3 km minimum for pace records
    assert kinds["fastest_pace_run"].display == "6:00"
    assert kinds["most_steps_day"].on == date(2026, 11, 3) and kinds["most_steps_day"].value == 15000
    assert kinds["most_exercise_day"].on == date(2026, 11, 2)
    assert "most_active_energy_day" not in kinds  # never recorded, never invented
    empty = a.personal_records([], [])
    assert not empty.available and empty.reason == "not_enough_data"


# ---------------------------------------------------------------- consistency


def test_consistency_streaks_and_sessions_per_week() -> None:
    start = TODAY - timedelta(days=27)  # Fri 16 Oct .. Fri 13 Nov
    rows = days(28, exercise_minutes=lambda i: 30 if i in (27, 26, 25, 20, 19) else 0)
    sessions = [
        run(f"w{i}", TODAY - timedelta(days=d), 5.0, 360.0) for i, d in enumerate((1, 2, 3, 8, 15, 16))
    ]
    r = a.consistency(rows, sessions, start, TODAY)
    assert r.available and r.days_with_data == 28
    assert r.current_streak_days == 4  # today, yesterday, 2 and 3 days ago
    assert r.longest_streak_days == 4
    assert r.active_days == 8 and r.avg_sessions_per_week is not None
    whole = [w for w in r.weeks if w.week_start >= start and w.week_start + timedelta(days=6) <= TODAY]
    assert len(whole) == 3 and r.avg_sessions_per_week == pytest.approx(
        sum(w.sessions for w in whole) / 3, abs=0.01
    )
    assert r.weeks_meeting_target == sum(1 for w in whole if w.sessions >= 3)


def test_consistency_needs_a_week_of_data() -> None:
    r = a.consistency(days(6, exercise_minutes=30), [], TODAY - timedelta(days=55), TODAY)
    assert not r.available and r.reason == "not_enough_data"


# ---------------------------------------------------------------- recovery observations


def test_recovery_observations_from_resting_heart_rate_and_sleep() -> None:
    rows = days(
        35,
        resting_heart_rate_bpm=lambda i: 64.0 if i >= 32 else 58.0,
        sleep_minutes=lambda i: 330 if i >= 32 else 420,
    )
    codes = {o.code for o in recovery_observations(rows, TODAY)}
    assert {"rhr_above_baseline", "short_sleep_run"} <= codes
    obs = next(o for o in recovery_observations(rows, TODAY) if o.code == "rhr_above_baseline")
    assert obs.values["delta"] == 6
    for lang in ("en", "hi", "hinglish"):
        text = render_observation(obs, lang)
        assert text and "6" in text and "bpm" in text


def test_recovery_observations_need_enough_history() -> None:
    assert recovery_observations(days(5, resting_heart_rate_bpm=70.0), TODAY) == []
    lower = days(35, resting_heart_rate_bpm=lambda i: 52.0 if i >= 32 else 58.0)
    assert [o.code for o in recovery_observations(lower, TODAY)] == ["rhr_below_baseline"]
    steady = days(35, resting_heart_rate_bpm=58.0, sleep_minutes=420)
    assert recovery_observations(steady, TODAY) == []


def test_training_load_observation() -> None:
    rows = days(35, exercise_minutes=lambda i: 60 if i >= 28 else 20)
    obs = [o for o in recovery_observations(rows, TODAY) if o.code == "load_up"]
    assert len(obs) == 1 and obs[0].values["ratio_pct"] == 300


def test_daily_summary_keeps_nulls_null() -> None:
    rows = days(3, steps=lambda i: 1000 * (i + 1))
    summary = a.daily_summary(rows[-1], [], rows)
    assert summary.steps == 3000 and summary.sleep_hours is None and summary.distance_km is None
    assert summary.resting_heart_rate_bpm is None and summary.workouts == []
