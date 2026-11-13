"""Fitness tables on the shared Base: daily aggregates, workouts and a sync log.

Only aggregates the device posts live here (raw HealthKit samples never leave the phone). Columns are
nullable on purpose: a null is "not available", never a zero.
"""

from __future__ import annotations

import datetime as dt
from datetime import datetime

from sqlalchemy import Boolean, Date, Float, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime
from app.db.types import JSONType


class FitnessDay(Base):
    __tablename__ = "fitness_days"

    date: Mapped[dt.date] = mapped_column(Date, primary_key=True)
    steps: Mapped[float | None] = mapped_column(Float, nullable=True)
    walking_running_distance_m: Mapped[float | None] = mapped_column(Float, nullable=True)
    cycling_distance_m: Mapped[float | None] = mapped_column(Float, nullable=True)
    active_energy_kcal: Mapped[float | None] = mapped_column(Float, nullable=True)
    exercise_minutes: Mapped[float | None] = mapped_column(Float, nullable=True)
    resting_heart_rate_bpm: Mapped[float | None] = mapped_column(Float, nullable=True)
    avg_heart_rate_bpm: Mapped[float | None] = mapped_column(Float, nullable=True)
    sleep_minutes: Mapped[float | None] = mapped_column(Float, nullable=True)
    body_mass_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    sources: Mapped[list[str]] = mapped_column(JSONType, default=list)
    source_generated_at: Mapped[datetime] = mapped_column(UTCDateTime)  # the device's generated_at
    synced_at: Mapped[datetime] = mapped_column(UTCDateTime)  # when the backend stored it


class FitnessWorkout(Base):
    __tablename__ = "fitness_workouts"

    id: Mapped[str] = mapped_column(String(120), primary_key=True)  # HealthKit uuid or "strava:<id>"
    origin: Mapped[str] = mapped_column(String(16), index=True)  # "healthkit" | "strava"
    type: Mapped[str] = mapped_column(String(16), index=True)
    start_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    end_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    local_date: Mapped[dt.date] = mapped_column(Date, index=True)  # the date on the device's own clock
    duration_s: Mapped[float | None] = mapped_column(Float, nullable=True)
    distance_m: Mapped[float | None] = mapped_column(Float, nullable=True)
    active_energy_kcal: Mapped[float | None] = mapped_column(Float, nullable=True)
    avg_heart_rate_bpm: Mapped[float | None] = mapped_column(Float, nullable=True)
    avg_pace_s_per_km: Mapped[float | None] = mapped_column(Float, nullable=True)
    source: Mapped[str | None] = mapped_column(String(80), nullable=True)
    # Strava data may be shown to its owner only: never placed in a prompt for an external model.
    ai_restricted: Mapped[bool] = mapped_column(Boolean, default=False)
    source_generated_at: Mapped[datetime] = mapped_column(UTCDateTime)
    synced_at: Mapped[datetime] = mapped_column(UTCDateTime)


class FitnessSyncLog(Base):
    __tablename__ = "fitness_sync_log"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    origin: Mapped[str] = mapped_column(String(16))
    received_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    generated_at: Mapped[datetime] = mapped_column(UTCDateTime)
    days_count: Mapped[int] = mapped_column(Integer, default=0)
    workouts_count: Mapped[int] = mapped_column(Integer, default=0)
