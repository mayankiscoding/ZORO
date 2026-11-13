"""Fitness sync payload (docs/architecture/device-contract.md, "Fitness sync") and shared models.

Every measurement may be null (the owner has not granted that HealthKit type). Nulls are stored as
nulls; nothing is estimated or filled in.
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator

WorkoutType = Literal["running", "walking", "cycling", "strength", "yoga", "swimming", "other"]
WORKOUT_TYPES: frozenset[str] = frozenset(
    {"running", "walking", "cycling", "strength", "yoga", "swimming", "other"}
)

MAX_DAYS_PER_SYNC = 400
MAX_WORKOUTS_PER_SYNC = 2000


class FModel(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)


NonNeg = Annotated[float, Field(ge=0, le=10_000_000, allow_inf_nan=False)]


class DayIn(FModel):
    date: date
    steps: Annotated[float, Field(ge=0, le=300_000, allow_inf_nan=False)] | None = None
    walking_running_distance_m: NonNeg | None = None
    cycling_distance_m: NonNeg | None = None
    active_energy_kcal: Annotated[float, Field(ge=0, le=50_000, allow_inf_nan=False)] | None = None
    exercise_minutes: Annotated[float, Field(ge=0, le=1440, allow_inf_nan=False)] | None = None
    resting_heart_rate_bpm: Annotated[float, Field(ge=20, le=250, allow_inf_nan=False)] | None = None
    avg_heart_rate_bpm: Annotated[float, Field(ge=20, le=250, allow_inf_nan=False)] | None = None
    sleep_minutes: Annotated[float, Field(ge=0, le=1440, allow_inf_nan=False)] | None = None
    body_mass_kg: Annotated[float, Field(gt=0, le=700, allow_inf_nan=False)] | None = None
    sources: list[Annotated[str, Field(max_length=80)]] = Field(default_factory=list, max_length=20)


class WorkoutIn(FModel):
    id: Annotated[str, Field(min_length=1, max_length=100)]
    type: WorkoutType = "other"
    start_at: AwareDatetime
    end_at: AwareDatetime | None = None
    duration_s: Annotated[float, Field(ge=0, le=7 * 86400, allow_inf_nan=False)] | None = None
    distance_m: NonNeg | None = None
    active_energy_kcal: Annotated[float, Field(ge=0, le=50_000, allow_inf_nan=False)] | None = None
    avg_heart_rate_bpm: Annotated[float, Field(ge=20, le=250, allow_inf_nan=False)] | None = None
    avg_pace_s_per_km: Annotated[float, Field(gt=0, le=7200, allow_inf_nan=False)] | None = None
    source: Annotated[str, Field(max_length=80)] | None = None

    @field_validator("type", mode="before")
    @classmethod
    def _known_type(cls, value: object) -> object:
        """An activity type this contract does not list becomes "other" instead of failing the sync."""
        return value if isinstance(value, str) and value in WORKOUT_TYPES else "other"


class SyncIn(FModel):
    generated_at: AwareDatetime
    days: list[DayIn] = Field(default_factory=list, max_length=MAX_DAYS_PER_SYNC)
    workouts: list[WorkoutIn] = Field(default_factory=list, max_length=MAX_WORKOUTS_PER_SYNC)


class SyncOut(FModel):
    received_at: AwareDatetime
    generated_at: AwareDatetime
    days_created: int
    days_updated: int
    days_skipped_older: int
    workouts_created: int
    workouts_updated: int
    workouts_skipped_older: int


class Freshness(FModel):
    """How old the data behind an answer is. `age_value` / `age_unit` are what gets spoken."""

    last_synced_at: datetime | None = None
    latest_data_date: date | None = None
    age_value: int | None = None
    age_unit: Literal["minutes", "hours", "days"] | None = None
    stale: bool = True  # older than 36 hours, or never synced
