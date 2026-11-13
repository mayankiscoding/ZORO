"""Automation tables: routines and their run history.

A run keeps a copy of the steps it was started with, so editing a routine never changes a run that is
already waiting for an approval. Step results (which may hold personal data) are kept sealed in
`results_enc`; the visible history holds only short summaries and status codes.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import Boolean, Float, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime
from app.db.types import JSONType


class Routine(Base):
    __tablename__ = "automation_routines"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(80), unique=True)
    description: Mapped[str] = mapped_column(String(300), default="")
    steps: Mapped[list[dict[str, Any]]] = mapped_column(JSONType)  # [{"tool": str, "args": {...template...}}]
    trigger: Mapped[dict[str, Any]] = mapped_column(
        JSONType
    )  # {"kind": "manual" | "daily" | "weekly" | "interval", ...}
    timezone: Mapped[str] = mapped_column(String(64), default="Asia/Kolkata")
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    next_run_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True, index=True)
    last_run_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)


class RoutineRun(Base):
    __tablename__ = "automation_runs"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    routine_id: Mapped[str] = mapped_column(String(64), index=True)
    routine_name: Mapped[str] = mapped_column(String(80))
    # running | awaiting_approval | awaiting_device | completed | failed | cancelled | timed_out
    status: Mapped[str] = mapped_column(String(24), index=True)
    trigger_kind: Mapped[str] = mapped_column(String(16))  # "manual" | "schedule"
    steps: Mapped[list[dict[str, Any]]] = mapped_column(JSONType)
    params: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict)
    step_index: Mapped[int] = mapped_column(Integer, default=0)
    step_log: Mapped[list[dict[str, Any]]] = mapped_column(JSONType, default=list)
    pending: Mapped[dict[str, Any] | None] = mapped_column(JSONType, nullable=True)
    results_enc: Mapped[str | None] = mapped_column(Text, nullable=True)
    tainted: Mapped[bool] = mapped_column(Boolean, default=False)
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    lang: Mapped[str] = mapped_column(String(12), default="en")
    timezone: Mapped[str] = mapped_column(String(64), default="Asia/Kolkata")
    active_s: Mapped[float] = mapped_column(
        Float, default=0.0
    )  # time spent executing (waiting is not counted)
    error: Mapped[str | None] = mapped_column(String(200), nullable=True)
    started_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)
    finished_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
