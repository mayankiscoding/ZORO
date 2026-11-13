"""Tool outputs. Every answer carries its data source and how fresh it is; when there is not enough
data it says so (`available=False`, `reason`) instead of estimating."""

from __future__ import annotations

from datetime import date
from typing import Literal

from pydantic import Field

from app.fitness.observations import Observation
from app.fitness.schemas import FModel, Freshness

Reason = Literal[
    "never_synced",
    "no_data_for_date",
    "no_data_in_window",
    "not_enough_data",
    "no_running_data",
]


class Sourced(FModel):
    available: bool = True
    reason: Reason | None = None
    data_source: str = "Apple Health (synced from your iPhone)"
    devices: list[str] = Field(default_factory=list)
    freshness: Freshness = Field(default_factory=Freshness)
    # False when any Strava activity contributed: Strava data must not go into an external model prompt.
    external_model_allowed: bool = True
    observations: list[Observation] = Field(default_factory=list)


class WorkoutBrief(FModel):
    id: str
    type: str
    start_at: str  # local ISO time
    duration_min: float | None = None
    distance_km: float | None = None
    pace_text: str | None = None  # "6:24" per km
    avg_heart_rate_bpm: int | None = None
    origin: str = "healthkit"


class DailySummary(Sourced):
    date: date
    steps: int | None = None
    distance_km: float | None = None
    cycling_km: float | None = None
    active_energy_kcal: int | None = None
    exercise_minutes: int | None = None
    resting_heart_rate_bpm: int | None = None
    avg_heart_rate_bpm: int | None = None
    sleep_hours: float | None = None
    body_mass_kg: float | None = None
    workouts: list[WorkoutBrief] = Field(default_factory=list)


class MetricComparison(FModel):
    metric: str
    unit: str
    current_avg: float | None = None
    previous_avg: float | None = None
    current_total: float | None = None
    previous_total: float | None = None
    change_pct: float | None = None
    days_current: int = 0
    days_previous: int = 0
    enough_data: bool = False


class WeeklyComparison(Sourced):
    current_start: date | None = None
    current_end: date | None = None
    previous_start: date | None = None
    previous_end: date | None = None
    metrics: list[MetricComparison] = Field(default_factory=list)
    workouts_current: int = 0
    workouts_previous: int = 0


class TrendResult(Sourced):
    metric: str = ""
    unit: str = ""
    window_start: date | None = None
    window_end: date | None = None
    points_used: int = 0
    min_points: int = 7
    slope_per_week: float | None = None
    mean: float | None = None
    direction: Literal["up", "down", "steady", "insufficient_data"] = "insufficient_data"


class WeeklyKm(FModel):
    week_start: date
    km: float
    runs: int


class RunningProgress(Sourced):
    window_start: date | None = None
    window_end: date | None = None
    runs: int = 0
    total_km: float = 0
    avg_pace_s_per_km: float | None = None
    avg_pace_text: str | None = None
    recent_pace_text: str | None = None  # the last three runs
    pace_change_s_per_km_per_week: float | None = None
    direction: Literal["faster", "slower", "steady", "insufficient_data"] = "insufficient_data"
    min_runs: int = 4
    weekly: list[WeeklyKm] = Field(default_factory=list)


class PersonalRecord(FModel):
    kind: Literal[
        "longest_run",
        "fastest_pace_run",
        "longest_workout",
        "most_steps_day",
        "most_exercise_day",
        "most_active_energy_day",
    ]
    value: float
    unit: str
    display: str  # e.g. "10.4" or "5:12" so the spoken figure is exactly this text
    on: date
    workout_id: str | None = None
    source: str | None = None


class PersonalRecords(Sourced):
    records: list[PersonalRecord] = Field(default_factory=list)
    note: str = "Whole-workout records; split times are not part of the Apple Health aggregates."


class WeekSessions(FModel):
    week_start: date
    sessions: int
    active_days: int


class Consistency(Sourced):
    window_start: date | None = None
    window_end: date | None = None
    min_active_minutes: int = 20
    days_with_data: int = 0
    active_days: int = 0
    current_streak_days: int = 0
    longest_streak_days: int = 0
    avg_sessions_per_week: float | None = None
    target_sessions_per_week: int = 3
    weeks_meeting_target: int = 0
    weeks: list[WeekSessions] = Field(default_factory=list)
