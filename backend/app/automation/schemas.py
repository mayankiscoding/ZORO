"""Automation contracts: routines, triggers, runs."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.automation.templates import TemplateError, check_syntax

MAX_STEPS = 10
MAX_NAME = 80
MIN_INTERVAL_MINUTES = 15
DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
_HHMM = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
_TOOL = re.compile(r"^[a-z][a-z0-9_]*(\.[A-Za-z0-9_-]+)+$")

RunStatus = Literal[
    "running", "awaiting_approval", "awaiting_device", "completed", "failed", "cancelled", "timed_out"
]
FORBIDDEN_TOOLS = frozenset(
    {"automation.run_routine", "automation.save_routine"}
)  # no recursion, no self-editing
ACTIVE_STATUSES = ("running", "awaiting_approval", "awaiting_device")


class AModel(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)


class Trigger(AModel):
    """manual (only when asked), or a simple schedule in the routine's time zone:
    daily at HH:MM, weekly on named days at HH:MM, or every N minutes (15 or more)."""

    kind: Literal["manual", "daily", "weekly", "interval"] = "manual"
    time: str | None = None
    days: list[Literal["mon", "tue", "wed", "thu", "fri", "sat", "sun"]] | None = None
    every_minutes: int | None = None

    @field_validator("time")
    @classmethod
    def _time(cls, value: str | None) -> str | None:
        if value is not None and not _HHMM.match(value):
            raise ValueError('time must be 24-hour "HH:MM"')
        return value

    @model_validator(mode="after")
    def _shape(self) -> Trigger:
        if self.kind == "manual":
            if self.time or self.days or self.every_minutes:
                raise ValueError("a manual trigger takes no schedule fields")
        elif self.kind == "daily":
            if not self.time or self.days or self.every_minutes:
                raise ValueError('a daily trigger needs only "time"')
        elif self.kind == "weekly":
            if not self.time or not self.days or self.every_minutes:
                raise ValueError('a weekly trigger needs "days" and "time"')
            self.days = sorted(set(self.days), key=DAYS.index)
        elif self.kind == "interval":
            if self.every_minutes is None or self.time or self.days:
                raise ValueError('an interval trigger needs only "every_minutes"')
            if not MIN_INTERVAL_MINUTES <= self.every_minutes <= 7 * 24 * 60:
                raise ValueError(f"every_minutes must be between {MIN_INTERVAL_MINUTES} and {7 * 24 * 60}")
        return self


class Step(AModel):
    tool: Annotated[str, Field(pattern=_TOOL.pattern, max_length=120)]
    args: dict[str, Any] = Field(
        default_factory=dict
    )  # a template: "{{params.x}}", "{{now.date}}", "{{steps.0.field}}"


class RoutineIn(AModel):
    name: Annotated[str, Field(min_length=1, max_length=MAX_NAME)]
    description: Annotated[str, Field(max_length=300)] = ""
    steps: Annotated[list[Step], Field(min_length=1, max_length=MAX_STEPS)]
    trigger: Trigger = Field(default_factory=Trigger)
    enabled: bool = True
    timezone: Annotated[str, Field(max_length=64)] = "Asia/Kolkata"

    @field_validator("name")
    @classmethod
    def _name(cls, value: str) -> str:
        value = re.sub(r"\s+", " ", value).strip()
        if not value:
            raise ValueError("name must not be empty")
        return value

    @model_validator(mode="after")
    def _static_step_checks(self) -> RoutineIn:
        """What can be refused without the tool registry, so a bad routine never reaches an approval."""
        for index, step in enumerate(self.steps):
            if step.tool in FORBIDDEN_TOOLS:
                raise ValueError(f"Step {index + 1}: a routine cannot call {step.tool}.")
            try:
                check_syntax(step.args, index)
            except TemplateError as exc:
                raise ValueError(f"Step {index + 1}: {exc}") from exc
        return self


class RoutineOut(AModel):
    id: str
    name: str
    description: str = ""
    steps: list[Step]
    trigger: Trigger
    timezone: str
    enabled: bool
    next_run_at: datetime | None = None
    last_run_at: datetime | None = None
    last_run_status: str | None = None
    created: bool = False  # set on save: true when the routine is new


class StepLog(AModel):
    index: int
    tool: str
    status: Literal["completed", "denied", "failed", "waiting", "skipped"]
    summary: str | None = None
    error: str | None = None


class Pending(AModel):
    kind: Literal["approval", "device"]
    call_id: str
    step: int
    approval_id: str | None = None
    action_id: str | None = None
    title: str | None = None
    summary: str | None = None
    level: str | None = None
    expires_at: datetime | None = None
    request: dict[str, Any] | None = None  # the device action to run (kind == "device")


class RunOut(AModel):
    id: str
    routine_id: str
    routine_name: str
    status: RunStatus
    trigger_kind: Literal["manual", "schedule"]
    steps_total: int
    step_index: int
    step_log: list[StepLog] = Field(default_factory=list)
    pending: Pending | None = None
    error: str | None = None
    started_at: datetime
    finished_at: datetime | None = None


class RunBody(AModel):
    params: dict[str, str | int | float | bool] = Field(default_factory=dict, max_length=20)


class EnableBody(AModel):
    enabled: bool
