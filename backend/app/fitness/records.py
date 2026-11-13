"""Plain records the analytics work on (no ORM, no I/O)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime


@dataclass(frozen=True)
class DayRec:
    date: date
    steps: float | None = None
    walking_running_distance_m: float | None = None
    cycling_distance_m: float | None = None
    active_energy_kcal: float | None = None
    exercise_minutes: float | None = None
    resting_heart_rate_bpm: float | None = None
    avg_heart_rate_bpm: float | None = None
    sleep_minutes: float | None = None
    body_mass_kg: float | None = None
    sources: tuple[str, ...] = ()


@dataclass(frozen=True)
class WorkoutRec:
    id: str
    type: str
    start_at: datetime
    local_date: date
    origin: str = "healthkit"  # "healthkit" | "strava"
    end_at: datetime | None = None
    duration_s: float | None = None
    distance_m: float | None = None
    active_energy_kcal: float | None = None
    avg_heart_rate_bpm: float | None = None
    avg_pace_s_per_km: float | None = None
    source: str | None = None

    @property
    def pace_s_per_km(self) -> float | None:
        """Average pace: the device's own value, else duration / distance. Never invented."""
        if self.avg_pace_s_per_km:
            return self.avg_pace_s_per_km
        if self.duration_s and self.distance_m and self.distance_m >= 100:
            return self.duration_s / (self.distance_m / 1000.0)
        return None


@dataclass(frozen=True)
class SyncState:
    last_synced_at: datetime | None
    last_generated_at: datetime | None
    latest_day: date | None
