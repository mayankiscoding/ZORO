"""Fitness analytics: plain functions over `DayRec` / `WorkoutRec`. No I/O, no models, no estimates."""

from __future__ import annotations

from collections.abc import Callable
from datetime import date, timedelta

from app.fitness.observations import recovery_observations
from app.fitness.records import DayRec, WorkoutRec
from app.fitness.results import (
    Consistency,
    DailySummary,
    MetricComparison,
    PersonalRecord,
    PersonalRecords,
    RunningProgress,
    TrendResult,
    WeeklyComparison,
    WeeklyKm,
    WeekSessions,
    WorkoutBrief,
)
from app.fitness.stats import (
    MIN_TREND_POINTS,
    MIN_WINDOW_DAYS,
    direction,
    longest_streak,
    mean,
    pace_text,
    pct_change,
    slope,
    streak_ending,
    week_start,
)

Getter = Callable[[DayRec], float | None]

# metric -> (getter, unit). Distance is shown in kilometres, sleep in hours.
METRICS: dict[str, tuple[Getter, str]] = {
    "steps": (lambda d: d.steps, "steps"),
    "exercise_minutes": (lambda d: d.exercise_minutes, "minutes"),
    "active_energy_kcal": (lambda d: d.active_energy_kcal, "kcal"),
    "sleep_hours": (lambda d: None if d.sleep_minutes is None else d.sleep_minutes / 60.0, "hours"),
    "resting_heart_rate_bpm": (lambda d: d.resting_heart_rate_bpm, "bpm"),
    "body_mass_kg": (lambda d: d.body_mass_kg, "kg"),
    "distance_km": (
        lambda d: None if d.walking_running_distance_m is None else d.walking_running_distance_m / 1000.0,
        "km",
    ),
}
RUN_MIN_DISTANCE_M = 1000.0
PR_PACE_MIN_DISTANCE_M = 3000.0
MIN_RUNS = 4
MIN_CONSISTENCY_DAYS = 7


def _r(value: float | None, places: int = 1) -> float | None:
    return None if value is None else round(value, places)


def _i(value: float | None) -> int | None:
    return None if value is None else round(value)


def _local_iso(w: WorkoutRec) -> str:
    return w.start_at.isoformat(timespec="minutes")


def brief(w: WorkoutRec) -> WorkoutBrief:
    return WorkoutBrief(
        id=w.id,
        type=w.type,
        start_at=_local_iso(w),
        duration_min=_r(None if w.duration_s is None else w.duration_s / 60.0),
        distance_km=_r(None if w.distance_m is None else w.distance_m / 1000.0, 2),
        pace_text=pace_text(w.pace_s_per_km) if w.type in ("running", "walking") else None,
        avg_heart_rate_bpm=_i(w.avg_heart_rate_bpm),
        origin=w.origin,
    )


def daily_summary(day: DayRec, workouts: list[WorkoutRec], history: list[DayRec]) -> DailySummary:
    todays = [w for w in workouts if w.local_date == day.date]
    return DailySummary(
        date=day.date,
        steps=_i(day.steps),
        distance_km=_r(_km(day.walking_running_distance_m), 2),
        cycling_km=_r(_km(day.cycling_distance_m), 2),
        active_energy_kcal=_i(day.active_energy_kcal),
        exercise_minutes=_i(day.exercise_minutes),
        resting_heart_rate_bpm=_i(day.resting_heart_rate_bpm),
        avg_heart_rate_bpm=_i(day.avg_heart_rate_bpm),
        sleep_hours=_r(None if day.sleep_minutes is None else day.sleep_minutes / 60.0),
        body_mass_kg=_r(day.body_mass_kg),
        workouts=[brief(w) for w in todays],
        devices=list(day.sources),
        observations=recovery_observations(history, day.date),
    )


def _km(metres: float | None) -> float | None:
    return None if metres is None else metres / 1000.0


def weekly_comparison(days: list[DayRec], workouts: list[WorkoutRec], end: date) -> WeeklyComparison:
    cur_start, prev_end = end - timedelta(days=6), end - timedelta(days=7)
    prev_start = end - timedelta(days=13)
    cur = [d for d in days if cur_start <= d.date <= end]
    prev = [d for d in days if prev_start <= d.date <= prev_end]
    metrics: list[MetricComparison] = []
    for name, (get, unit) in METRICS.items():
        cv = [v for d in cur if (v := get(d)) is not None]
        pv = [v for d in prev if (v := get(d)) is not None]
        enough = len(cv) >= MIN_WINDOW_DAYS and len(pv) >= MIN_WINDOW_DAYS
        ca, pa = mean(cv), mean(pv)
        metrics.append(
            MetricComparison(
                metric=name,
                unit=unit,
                current_avg=_r(ca, 2),
                previous_avg=_r(pa, 2),
                current_total=_r(sum(cv), 1) if cv else None,
                previous_total=_r(sum(pv), 1) if pv else None,
                change_pct=_r(pct_change(ca, pa), 1) if enough else None,
                days_current=len(cv),
                days_previous=len(pv),
                enough_data=enough,
            )
        )
    wc = sum(1 for w in workouts if cur_start <= w.local_date <= end)
    wp = sum(1 for w in workouts if prev_start <= w.local_date <= prev_end)
    return WeeklyComparison(
        current_start=cur_start,
        current_end=end,
        previous_start=prev_start,
        previous_end=prev_end,
        metrics=metrics,
        workouts_current=wc,
        workouts_previous=wp,
        observations=recovery_observations(days, end),
        available=any(m.enough_data for m in metrics) or wc + wp > 0,
        reason=None if any(m.enough_data for m in metrics) or wc + wp > 0 else "not_enough_data",
    )


def trend(days: list[DayRec], metric: str, start: date, end: date) -> TrendResult:
    get, unit = METRICS[metric]
    pts = [(d.date, v) for d in days if start <= d.date <= end and (v := get(d)) is not None]
    base = TrendResult(metric=metric, unit=unit, window_start=start, window_end=end, points_used=len(pts))
    if len(pts) < MIN_TREND_POINTS:
        return base.model_copy(update={"available": False, "reason": "not_enough_data"})
    xs = [float((d - start).days) for d, _ in pts]
    ys = [v for _, v in pts]
    per_day = slope(xs, ys)
    avg = mean(ys)
    if per_day is None or avg is None:
        return base.model_copy(update={"available": False, "reason": "not_enough_data"})
    span = (end - start).days
    return base.model_copy(
        update={
            "slope_per_week": round(per_day * 7, 3),
            "mean": round(avg, 2),
            "direction": direction(per_day, span, avg),
        }
    )


def _runs(workouts: list[WorkoutRec]) -> list[WorkoutRec]:
    return [w for w in workouts if w.type == "running" and (w.distance_m or 0) >= RUN_MIN_DISTANCE_M]


def running_progress(workouts: list[WorkoutRec], start: date, end: date) -> RunningProgress:
    runs = [w for w in _runs(workouts) if start <= w.local_date <= end]
    base = RunningProgress(window_start=start, window_end=end, runs=len(runs), min_runs=MIN_RUNS)
    if not runs:
        return base.model_copy(update={"available": False, "reason": "no_running_data"})
    total_km = sum((w.distance_m or 0) / 1000.0 for w in runs)
    weeks: dict[date, list[WorkoutRec]] = {}
    for w in runs:
        weeks.setdefault(week_start(w.local_date), []).append(w)
    weekly = [
        WeeklyKm(
            week_start=ws, km=round(sum((w.distance_m or 0) / 1000.0 for w in ws_runs), 2), runs=len(ws_runs)
        )
        for ws, ws_runs in sorted(weeks.items())
    ]
    paced = [(w, p) for w in runs if (p := w.pace_s_per_km) is not None]
    update: dict[str, object] = {"total_km": round(total_km, 2), "weekly": weekly}
    if paced:
        avg = mean([p for _, p in paced])
        update["avg_pace_s_per_km"] = _r(avg, 1)
        update["avg_pace_text"] = pace_text(avg)
        update["recent_pace_text"] = pace_text(mean([p for _, p in paced[-3:]]))
    if len(paced) < MIN_RUNS:
        update.update(available=len(paced) > 0, reason="not_enough_data" if paced else "no_running_data")
        return base.model_copy(update=update)
    first = paced[0][0].local_date
    xs = [float((w.local_date - first).days) for w, _ in paced]
    per_day = slope(xs, [p for _, p in paced], min_points=MIN_RUNS)
    avg_pace = mean([p for _, p in paced]) or 0.0
    if per_day is not None:
        span = max(xs[-1] - xs[0], 1.0)
        kind = direction(per_day, span, avg_pace)  # pace in s/km: lower is faster
        update["pace_change_s_per_km_per_week"] = round(per_day * 7, 2)
        update["direction"] = {"up": "slower", "down": "faster", "steady": "steady"}[kind]
    return base.model_copy(update=update)


def personal_records(days: list[DayRec], workouts: list[WorkoutRec]) -> PersonalRecords:
    recs: list[PersonalRecord] = []
    runs = _runs(workouts)
    if runs:
        w = max(runs, key=lambda x: x.distance_m or 0)
        km = (w.distance_m or 0) / 1000.0
        recs.append(
            PersonalRecord(
                kind="longest_run",
                value=round(km, 2),
                unit="km",
                display=f"{km:.1f}",
                on=w.local_date,
                workout_id=w.id,
                source=w.source,
            )
        )
    fast = [w for w in runs if (w.distance_m or 0) >= PR_PACE_MIN_DISTANCE_M and w.pace_s_per_km]
    if fast:
        w = min(fast, key=lambda x: x.pace_s_per_km or 1e9)
        recs.append(
            PersonalRecord(
                kind="fastest_pace_run",
                value=round(w.pace_s_per_km or 0, 1),
                unit="s/km",
                display=pace_text(w.pace_s_per_km) or "",
                on=w.local_date,
                workout_id=w.id,
                source=w.source,
            )
        )
    timed = [w for w in workouts if w.duration_s]
    if timed:
        w = max(timed, key=lambda x: x.duration_s or 0)
        minutes = (w.duration_s or 0) / 60.0
        recs.append(
            PersonalRecord(
                kind="longest_workout",
                value=round(minutes, 1),
                unit="minutes",
                display=f"{minutes:.0f}",
                on=w.local_date,
                workout_id=w.id,
                source=w.source,
            )
        )
    for kind, field, unit in (
        ("most_steps_day", "steps", "steps"),
        ("most_exercise_day", "exercise_minutes", "minutes"),
        ("most_active_energy_day", "active_energy_kcal", "kcal"),
    ):
        have = [d for d in days if getattr(d, field) is not None]
        if have:
            best = max(have, key=lambda d: getattr(d, field))
            value = float(getattr(best, field))
            recs.append(
                PersonalRecord(
                    kind=kind,
                    value=round(value),
                    unit=unit,
                    display=f"{value:.0f}",
                    on=best.date,
                    source=", ".join(best.sources) or None,
                )
            )
    if not recs:
        return PersonalRecords(available=False, reason="not_enough_data")
    return PersonalRecords(records=recs)


def consistency(
    days: list[DayRec],
    workouts: list[WorkoutRec],
    start: date,
    end: date,
    *,
    min_active_minutes: int = 20,
    target: int = 3,
) -> Consistency:
    in_window = [d for d in days if start <= d.date <= end]
    base = Consistency(
        window_start=start,
        window_end=end,
        min_active_minutes=min_active_minutes,
        days_with_data=len(in_window),
        target_sessions_per_week=target,
    )
    if len(in_window) < MIN_CONSISTENCY_DAYS:
        return base.model_copy(update={"available": False, "reason": "not_enough_data"})
    wk = [w for w in workouts if start <= w.local_date <= end]
    active = {d.date for d in in_window if (d.exercise_minutes or 0) >= min_active_minutes}
    active |= {w.local_date for w in wk}
    sessions: dict[date, int] = {}
    active_by_week: dict[date, int] = {}
    cursor = week_start(start)
    while cursor <= end:
        sessions[cursor] = 0
        active_by_week[cursor] = 0
        cursor += timedelta(days=7)
    for w in wk:
        sessions[week_start(w.local_date)] += 1
    for d in active:
        if start <= d <= end:
            active_by_week[week_start(d)] += 1
    # A week the window only touches (first / current partial week) is still listed, but the average
    # and the target count use whole weeks only.
    whole = [ws for ws in sessions if ws >= start and ws + timedelta(days=6) <= end]
    weeks = [
        WeekSessions(week_start=ws, sessions=sessions[ws], active_days=active_by_week[ws])
        for ws in sorted(sessions)
    ]
    return base.model_copy(
        update={
            "active_days": len([d for d in active if start <= d <= end]),
            "current_streak_days": streak_ending(active, end),
            "longest_streak_days": longest_streak(active),
            "avg_sessions_per_week": _r(sum(sessions[ws] for ws in whole) / len(whole), 2) if whole else None,
            "weeks_meeting_target": sum(1 for ws in whole if sessions[ws] >= target),
            "weeks": weeks,
        }
    )
