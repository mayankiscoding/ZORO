"""The `fitness_summary` card: metrics, observations (English), data source and freshness."""

from __future__ import annotations

from typing import Any

from app.fitness.observations import render_observation
from app.fitness.results import (
    Consistency,
    DailySummary,
    PersonalRecords,
    RunningProgress,
    Sourced,
    TrendResult,
    WeeklyComparison,
)
from app.fitness.service import RoutineOut, RunningPlanOut
from app.schemas.common import UICard


def _metrics(r: Any) -> list[dict[str, Any]]:
    def m(label: str, value: Any, unit: str = "") -> dict[str, Any]:
        return {"label": label, "value": value, "unit": unit}

    if isinstance(r, DailySummary):
        pairs = [
            ("Steps", r.steps, ""),
            ("Distance", r.distance_km, "km"),
            ("Active energy", r.active_energy_kcal, "kcal"),
            ("Exercise", r.exercise_minutes, "min"),
            ("Resting heart rate", r.resting_heart_rate_bpm, "bpm"),
            ("Sleep", r.sleep_hours, "h"),
            ("Body weight", r.body_mass_kg, "kg"),
        ]
        return [m(a, b, c) for a, b, c in pairs if b is not None]
    if isinstance(r, WeeklyComparison):
        return [
            m(x.metric.replace("_", " "), x.current_avg, x.unit)
            | {"previous": x.previous_avg, "change_pct": x.change_pct}
            for x in r.metrics
            if x.enough_data
        ]
    if isinstance(r, TrendResult):
        return [
            m(r.metric.replace("_", " "), r.mean, r.unit)
            | {"slope_per_week": r.slope_per_week, "direction": r.direction}
        ]
    if isinstance(r, RunningProgress):
        return [
            m("Runs", r.runs),
            m("Distance", r.total_km, "km"),
            m("Average pace", r.avg_pace_text, "per km"),
        ]
    if isinstance(r, PersonalRecords):
        return [
            m(x.kind.replace("_", " "), x.display, x.unit) | {"date": x.on.isoformat()} for x in r.records
        ]
    if isinstance(r, Consistency):
        return [
            m("Active days", r.active_days),
            m("Current streak", r.current_streak_days, "days"),
            m("Longest streak", r.longest_streak_days, "days"),
            m("Sessions per week", r.avg_sessions_per_week),
        ]
    return []


def card(r: Any, title: str) -> UICard | None:
    if not isinstance(r, Sourced) or not r.available:
        return None
    notes = [t for o in r.observations if (t := render_observation(o, "en"))]
    payload: dict[str, Any] = {
        "metrics": _metrics(r),
        "observations": notes,
        "data_source": r.data_source,
        "freshness": r.freshness.model_dump(mode="json"),
        "stale": r.freshness.stale,
        "external_model_allowed": r.external_model_allowed,
    }
    if isinstance(r, RunningPlanOut) and r.plan:
        payload["plan"] = r.plan.model_dump(mode="json")
    if isinstance(r, RoutineOut) and r.routine:
        payload["routine"] = r.routine.model_dump(mode="json")
    return UICard(kind="fitness_summary", title=title, payload=payload)
