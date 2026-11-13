"""Routine storage and validation: save (upsert by name), list, get, enable, delete, run history."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.automation.models import Routine, RoutineRun
from app.automation.schedule import next_run_after, zone_of
from app.automation.schemas import (
    ACTIVE_STATUSES,
    FORBIDDEN_TOOLS,
    MAX_STEPS,
    Pending,
    RoutineIn,
    RoutineOut,
    RunOut,
    Step,
    StepLog,
    Trigger,
)
from app.automation.templates import TemplateError, check_syntax, placeholders
from app.core.clock import Clock
from app.core.errors import Conflict, NotFound, ValidationFailed
from app.core.types import AgentId
from app.db.base import new_id
from app.db.session import SessionFactory
from app.tools.registry import ToolRegistry

MAX_ROUTINES = 50
MAX_RUNS_KEPT = 50
_WORD = re.compile(r"\s+")


class RoutineNotFound(NotFound):
    code = "routine_not_found"
    default_message = "No routine matches that name."


class RoutineAmbiguous(Conflict):
    code = "routine_ambiguous"
    default_message = "More than one routine matches that name."


class RoutineInvalid(ValidationFailed):
    code = "routine_invalid"
    default_message = "The routine is not valid."


class RoutineBusy(Conflict):
    code = "routine_busy"
    default_message = "This routine is already running or waiting for an approval."


class RoutineDisabled(Conflict):
    code = "routine_disabled"
    default_message = "This routine is turned off. Turn it on first."


class RunNotFound(NotFound):
    code = "run_not_found"
    default_message = "No such routine run."


class RunNotWaiting(Conflict):
    code = "run_not_waiting"
    default_message = "This run is not waiting for an approval or a device."


def routine_out(row: Routine, *, last_status: str | None = None, created: bool = False) -> RoutineOut:
    return RoutineOut(
        id=row.id,
        name=row.name,
        description=row.description,
        steps=[Step.model_validate(s) for s in row.steps],
        trigger=Trigger.model_validate(row.trigger),
        timezone=row.timezone,
        enabled=row.enabled,
        next_run_at=row.next_run_at,
        last_run_at=row.last_run_at,
        last_run_status=last_status,
        created=created,
    )


def run_out(row: RoutineRun) -> RunOut:
    return RunOut(
        id=row.id,
        routine_id=row.routine_id,
        routine_name=row.routine_name,
        status=row.status,
        trigger_kind=row.trigger_kind,
        steps_total=len(row.steps),
        step_index=row.step_index,
        step_log=[StepLog.model_validate(s) for s in row.step_log or []],
        pending=Pending.model_validate(row.pending) if row.pending else None,
        error=row.error,
        started_at=row.started_at,
        finished_at=row.finished_at,
    )


class RoutineService:
    def __init__(self, session_factory: SessionFactory, clock: Clock, tools: ToolRegistry) -> None:
        self._sf = session_factory
        self._clock = clock
        self._tools = tools

    # ------------------------------------------------------------ validation

    def validate_steps(self, steps: list[dict[str, Any]]) -> None:
        """Every step names a registered tool the automation agent may call; templates must resolve."""
        if not 1 <= len(steps) <= MAX_STEPS:
            raise RoutineInvalid(f"A routine has 1 to {MAX_STEPS} steps.")
        for index, step in enumerate(steps):
            name = step["tool"]
            tool = self._tools.get(name)
            if name in FORBIDDEN_TOOLS:
                raise RoutineInvalid(f"Step {index + 1}: a routine cannot call {name}.")
            if tool is None:
                raise RoutineInvalid(
                    f"Step {index + 1}: no tool named {name}.", detail={"step": index, "tool": name}
                )
            if AgentId.AUTOMATION not in tool.agents:
                raise RoutineInvalid(
                    f"Step {index + 1}: routines may not call {name}.", detail={"step": index}
                )
            try:
                check_syntax(step["args"], index)
            except TemplateError as exc:
                raise RoutineInvalid(f"Step {index + 1}: {exc}", detail={"step": index}) from exc
            if not placeholders(step["args"]):
                try:
                    tool.input_model.model_validate(step["args"])
                except ValueError as exc:
                    raise RoutineInvalid(
                        f"Step {index + 1}: the arguments do not fit {name}.", detail={"step": index}
                    ) from exc

    # ------------------------------------------------------------ routines

    async def _find(self, session: AsyncSession, ref: str) -> Routine:
        row = await session.get(Routine, ref)
        if row is not None:
            return row
        wanted = _WORD.sub(" ", ref).strip().casefold()
        rows = (await session.scalars(select(Routine))).all()
        exact = [r for r in rows if r.name.casefold() == wanted]
        if len(exact) == 1:
            return exact[0]
        partial = [r for r in rows if wanted and wanted in r.name.casefold()]
        if len(partial) == 1:
            return partial[0]
        if len(partial) > 1:
            raise RoutineAmbiguous(detail={"names": sorted(r.name for r in partial)})
        raise RoutineNotFound()

    async def save(self, data: RoutineIn, *, created_by: str | None = None) -> RoutineOut:
        steps = [s.model_dump() for s in data.steps]
        self.validate_steps(steps)
        zone_of(data.timezone)
        now = self._clock.now()
        nxt = next_run_after(data.trigger, now, data.timezone) if data.enabled else None
        async with self._sf() as session:
            rows = (await session.scalars(select(Routine))).all()  # at most MAX_ROUTINES
            existing = next((r for r in rows if r.name.casefold() == data.name.casefold()), None)
            created = existing is None
            if existing is None:
                if (await session.scalar(select(func.count()).select_from(Routine)) or 0) >= MAX_ROUTINES:
                    raise Conflict(f"At most {MAX_ROUTINES} routines are kept.", code="too_many_routines")
                existing = Routine(id=new_id("rtn"), name=data.name, created_at=now, created_by=created_by)
                session.add(existing)
            existing.description = data.description
            existing.steps = steps
            existing.trigger = data.trigger.model_dump(mode="json", exclude_none=True)
            existing.timezone = data.timezone
            existing.enabled = data.enabled
            existing.next_run_at = nxt
            existing.updated_at = now
            await session.commit()
            return routine_out(existing, created=created)

    async def list_all(self, *, include_disabled: bool = True) -> list[RoutineOut]:
        async with self._sf() as session:
            stmt = select(Routine).order_by(Routine.name)
            if not include_disabled:
                stmt = stmt.where(Routine.enabled.is_(True))
            rows = (await session.scalars(stmt)).all()
            return [routine_out(r, last_status=await self._last_status(session, r.id)) for r in rows]

    async def _last_status(self, session: AsyncSession, routine_id: str) -> str | None:
        return await session.scalar(
            select(RoutineRun.status)
            .where(RoutineRun.routine_id == routine_id)
            .order_by(RoutineRun.started_at.desc())
            .limit(1)
        )

    async def get(self, ref: str) -> RoutineOut:
        async with self._sf() as session:
            row = await self._find(session, ref)
            return routine_out(row, last_status=await self._last_status(session, row.id))

    async def set_enabled(self, ref: str, enabled: bool) -> RoutineOut:
        now = self._clock.now()
        async with self._sf() as session:
            row = await self._find(session, ref)
            row.enabled = enabled
            row.updated_at = now
            row.next_run_at = (
                next_run_after(Trigger.model_validate(row.trigger), now, row.timezone) if enabled else None
            )
            await session.commit()
            return routine_out(row)

    async def delete(self, ref: str) -> None:
        async with self._sf() as session:
            row = await self._find(session, ref)
            await session.execute(
                delete(RoutineRun).where(
                    RoutineRun.routine_id == row.id, RoutineRun.status.notin_(ACTIVE_STATUSES)
                )
            )
            await session.delete(row)
            await session.commit()

    # ------------------------------------------------------------ runs

    async def runs(self, ref: str, limit: int = 20) -> list[RunOut]:
        async with self._sf() as session:
            row = await self._find(session, ref)
            found = await session.scalars(
                select(RoutineRun)
                .where(RoutineRun.routine_id == row.id)
                .order_by(RoutineRun.started_at.desc())
                .limit(limit)
            )
            return [run_out(r) for r in found.all()]

    async def get_run(self, run_id: str) -> RunOut:
        async with self._sf() as session:
            row = await session.get(RoutineRun, run_id)
            if row is None:
                raise RunNotFound()
            return run_out(row)

    async def prune_history(self, routine_id: str) -> None:
        async with self._sf() as session:
            keep = (
                await session.scalars(
                    select(RoutineRun.id)
                    .where(RoutineRun.routine_id == routine_id)
                    .order_by(RoutineRun.started_at.desc())
                    .limit(MAX_RUNS_KEPT)
                )
            ).all()
            await session.execute(
                delete(RoutineRun).where(
                    RoutineRun.routine_id == routine_id,
                    RoutineRun.id.notin_(keep),
                    RoutineRun.status.notin_(ACTIVE_STATUSES),
                )
            )
            await session.commit()

    async def mark_scheduled(self, routine_id: str, when: datetime, next_at: datetime | None) -> None:
        async with self._sf() as session:
            row = await session.get(Routine, routine_id)
            if row is not None:
                row.last_run_at, row.next_run_at = when, next_at
                await session.commit()
