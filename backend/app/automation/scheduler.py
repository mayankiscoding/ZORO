"""Bounded scheduler: a background task that starts due routines.

Bounds: one tick every `tick_s` seconds (at least 5), at most `max_due_per_tick` routines per tick, at
most `max_concurrent` runs at once, and a routine that was due more than `missed_grace` ago (the server
was off) is rescheduled without running, so a long outage never fires a pile of stale routines. A
routine with an active run is skipped (one active run per routine). The kill switch pauses ticking.
Started and stopped by the plugin's startup and shutdown hooks; `tick()` can be called directly.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
from datetime import timedelta
from typing import Any

from sqlalchemy import select

from app.automation.models import Routine
from app.automation.runner import RoutineRunner
from app.automation.schedule import next_run_after
from app.automation.schemas import Trigger
from app.core.errors import ZoroError

log = logging.getLogger(__name__)

MIN_TICK_S = 5.0


class RoutineScheduler:
    def __init__(
        self,
        reg: Any,
        runner: RoutineRunner,
        *,
        tick_s: float = 30.0,
        max_concurrent: int = 2,
        max_due_per_tick: int = 5,
        missed_grace: timedelta = timedelta(hours=6),
    ) -> None:
        self._reg = reg
        self._runner = runner
        self.tick_s = max(tick_s, MIN_TICK_S)
        self.max_due_per_tick = max_due_per_tick
        self.missed_grace = missed_grace
        self._slots = asyncio.Semaphore(max_concurrent)
        self._task: asyncio.Task[None] | None = None

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    async def tick(self) -> list[str]:
        """Start every routine that is due now. Returns the ids of the runs started."""
        if await self._reg.service("kill_switch").is_on():
            return []
        now = self._reg.service("clock").now()
        await self._runner.expire_waiting()
        async with self._reg.service("session_factory")() as session:
            due = (
                await session.scalars(
                    select(Routine)
                    .where(
                        Routine.enabled.is_(True),
                        Routine.next_run_at.is_not(None),
                        Routine.next_run_at <= now,
                    )
                    .order_by(Routine.next_run_at)
                    .limit(self.max_due_per_tick)
                )
            ).all()
            plan = [(r.id, r.next_run_at, Trigger.model_validate(r.trigger), r.timezone) for r in due]
        started: list[str] = []

        async def launch(routine_id: str) -> None:
            async with self._slots:
                try:
                    out = await self._runner.start(routine_id, trigger_kind="schedule", lang="en")
                    started.append(out.id)
                except ZoroError as exc:  # busy, disabled, invalid: skipped, never fatal
                    log.info(
                        "scheduled routine skipped", extra={"routine": routine_id, "code": exc.error_code}
                    )
                except Exception as exc:
                    log.error(
                        "scheduled routine failed",
                        extra={"routine": routine_id, "error_type": type(exc).__name__},
                    )

        jobs = []
        for routine_id, due_at, trigger, tz in plan:
            service = self._runner._service
            nxt = next_run_after(trigger, now, tz)
            if due_at is not None and now - due_at > self.missed_grace:
                await service.mark_scheduled(
                    routine_id, now, nxt
                )  # missed while the server was off: skip this one
                continue
            await service.mark_scheduled(
                routine_id, now, nxt
            )  # reschedule first: a slow run cannot fire twice
            jobs.append(launch(routine_id))
        await asyncio.gather(*jobs)
        return started

    async def _loop(self) -> None:
        while True:
            try:
                await self.tick()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.error("scheduler tick failed", extra={"error_type": type(exc).__name__})
            await asyncio.sleep(self.tick_s)

    async def start(self) -> None:
        if self.running or os.environ.get("ZORO_AUTOMATION_SCHEDULER", "on").lower() in ("off", "0", "false"):
            return
        await self._runner.recover_stale()
        self._task = asyncio.create_task(self._loop(), name="zoro-automation-scheduler")

    async def stop(self) -> None:
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
