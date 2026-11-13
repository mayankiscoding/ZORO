"""Routine runner: executes a routine's steps through the ToolExecutor, one at a time.

Every step runs as the automation agent with `user_initiated=False`, so the policy engine asks the
owner for approval on anything MEDIUM or above; the run then stops with status `awaiting_approval`
and continues only when the owner's signed decision arrives (`resume`). A step that must run on a
device the same way (`awaiting_device`). Limits: at most `MAX_STEPS` steps, `step_timeout_s` per
step, `run_time_limit_s` of active time per run (waiting for the owner does not count), one active run
per routine. Step calls use the id ``<run id>:<step>``, so executing or resuming twice never repeats a
step.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from sqlalchemy import select, update

from app.automation.models import Routine, RoutineRun
from app.automation.schedule import zone_of
from app.automation.schemas import ACTIVE_STATUSES, MAX_STEPS, Pending, RunOut
from app.automation.service import (
    RoutineBusy,
    RoutineDisabled,
    RoutineService,
    RunNotFound,
    RunNotWaiting,
    run_out,
)
from app.automation.templates import TemplateError, build_context, render
from app.core.errors import BadRequest
from app.core.types import AgentId
from app.db.base import new_id
from app.schemas.turns import ApprovalDecision, DeviceActionResult
from app.tools.outcome import Completed, Denied, Failed, NeedsApproval, NeedsDeviceAction, ToolOutcome

log = logging.getLogger(__name__)

# A denial that leaves the suspended call open (a wrong signature or a stale request): the run keeps waiting.
OPEN_DENIALS = frozenset(
    {
        "invalid_signature",
        "approval_digest_mismatch",
        "approval_not_found",
        "approval_mismatch",
        "wrong_device",
        "action_mismatch",
        "agent_mismatch",
    }
)
MAX_SUMMARY = 200


@dataclass(frozen=True)
class RunLimits:
    max_steps: int = MAX_STEPS
    step_timeout_s: float = 30.0
    run_time_limit_s: float = 120.0


def _settled(step_log: list[dict[str, Any]] | None, index: int) -> list[dict[str, Any]]:
    """The log without the "waiting" entry of a step that has now been answered."""
    return [e for e in (step_log or []) if not (e.get("index") == index and e.get("status") == "waiting")]


class RoutineRunner:
    def __init__(self, reg: Any, service: RoutineService, limits: RunLimits | None = None) -> None:
        self._reg = reg
        self._service = service
        self.limits = limits or RunLimits()
        self._locks: dict[str, asyncio.Lock] = {}

    # ------------------------------------------------------------ plumbing

    @property
    def _sf(self) -> Any:
        return self._reg.service("session_factory")

    def _now(self) -> Any:
        return self._reg.service("clock").now()

    def _lock(self, run_id: str) -> asyncio.Lock:
        return self._locks.setdefault(run_id, asyncio.Lock())

    async def _ctx(self, run: RoutineRun) -> Any:
        mode = await self._reg.service("privacy_state").get_mode()
        return self._reg.tool_context(
            turn_id=run.id,
            agent=AgentId.AUTOMATION,
            device_id=run.device_id,
            privacy_mode=mode,
            lang=run.lang,
            timezone=run.timezone,
            tainted=run.tainted,
            user_initiated=False,
        )

    async def _load(self, run_id: str) -> RoutineRun:
        async with self._sf() as session:
            row = await session.get(RoutineRun, run_id)
        if row is None:
            raise RunNotFound()
        assert isinstance(row, RoutineRun)
        return row

    async def _update(self, run_id: str, **fields: Any) -> None:
        async with self._sf() as session:
            await session.execute(
                update(RoutineRun).where(RoutineRun.id == run_id).values(updated_at=self._now(), **fields)
            )
            await session.commit()

    async def _claim(self, run_id: str, from_status: str) -> bool:
        """Compare-and-set `from_status` -> running; false when someone else already moved the run."""
        async with self._sf() as session:
            result = await session.execute(
                update(RoutineRun)
                .where(RoutineRun.id == run_id, RoutineRun.status == from_status)
                .values(status="running", updated_at=self._now())
            )
            await session.commit()
        return int(getattr(result, "rowcount", 0) or 0) == 1

    def _seal(self, run_id: str, results: list[Any]) -> str:
        sealed: str = self._reg.service("cipher").encrypt(
            json.dumps(results, default=str), aad=f"automation_run|{run_id}"
        )
        return sealed

    def _unseal(self, run: RoutineRun) -> list[Any]:
        if not run.results_enc:
            return []
        raw = self._reg.service("cipher").decrypt_str(run.results_enc, aad=f"automation_run|{run.id}")
        loaded = json.loads(raw)
        return loaded if isinstance(loaded, list) else []

    # ------------------------------------------------------------ start

    async def start(
        self,
        ref: str,
        *,
        params: dict[str, Any] | None = None,
        trigger_kind: str = "manual",
        device_id: str | None = None,
        lang: str = "en",
    ) -> RunOut:
        routine = await self._service.get(ref)
        if not routine.enabled:
            raise RoutineDisabled()
        if len(routine.steps) > self.limits.max_steps:
            raise BadRequest(f"A routine runs at most {self.limits.max_steps} steps.", code="too_many_steps")
        self._service.validate_steps([s.model_dump() for s in routine.steps])
        await self.expire_waiting(routine.id)
        now = self._now()
        run = RoutineRun(
            id=new_id("run"),
            routine_id=routine.id,
            routine_name=routine.name,
            status="running",
            trigger_kind=trigger_kind,
            steps=[s.model_dump() for s in routine.steps],
            params=dict(params or {}),
            step_index=0,
            step_log=[],
            pending=None,
            results_enc=None,
            tainted=False,
            device_id=device_id,
            lang=lang,
            timezone=routine.timezone,
            active_s=0.0,
            started_at=now,
            updated_at=now,
        )
        async with self._sf() as session:
            busy = await session.scalar(
                select(RoutineRun.id)
                .where(RoutineRun.routine_id == routine.id, RoutineRun.status.in_(ACTIVE_STATUSES))
                .limit(1)
            )
            if busy is not None:
                raise RoutineBusy(detail={"run_id": busy})
            session.add(run)
            await session.commit()
        await self._service.mark_scheduled(routine.id, now, routine.next_run_at)
        out = await self._advance(run.id)
        await self._service.prune_history(routine.id)
        return out

    # ------------------------------------------------------------ advance

    async def _advance(self, run_id: str) -> RunOut:
        async with self._lock(run_id):
            started = time.monotonic()
            while True:
                run = await self._load(run_id)
                if run.status != "running":
                    break
                if run.step_index >= len(run.steps):
                    await self._finish(run, "completed", started)
                    break
                remaining = self.limits.run_time_limit_s - run.active_s - (time.monotonic() - started)
                if remaining <= 0:
                    await self._finish(run, "timed_out", started, error="run_time_limit")
                    break
                step = run.steps[run.step_index]
                results = self._unseal(run)
                try:
                    context = build_context(run.params, results, self._now(), zone_of(run.timezone))
                    args = render(step["args"], context)
                except TemplateError as exc:
                    await self._fail_step(run, "failed", f"template: {exc}", started)
                    break
                ctx = await self._ctx(run)
                call_id = f"{run.id}:{run.step_index}"
                try:
                    outcome = await asyncio.wait_for(
                        self._reg.service("tool_executor").execute(ctx, step["tool"], args, call_id=call_id),
                        timeout=min(self.limits.step_timeout_s, remaining),
                    )
                except TimeoutError:
                    await self._fail_step(run, "failed", "step_timeout", started)
                    break
                except Exception as exc:  # the executor does not raise; this keeps a run from hanging
                    log.error("routine step raised", extra={"run": run.id, "error_type": type(exc).__name__})
                    await self._fail_step(run, "failed", "step_error", started)
                    break
                if not await self._apply(run, outcome, results, started):
                    break
            return run_out(await self._load(run_id))

    async def _apply(self, run: RoutineRun, outcome: ToolOutcome, results: list[Any], started: float) -> bool:
        """Record what a step came to. True when the run should go on to the next step."""
        index, tool = run.step_index, run.steps[run.step_index]["tool"]
        log_list = _settled(run.step_log, index)
        active = run.active_s + (time.monotonic() - started)
        if isinstance(outcome, Completed):
            summary = (outcome.summary or "")[:MAX_SUMMARY] or None
            log_list.append({"index": index, "tool": tool, "status": "completed", "summary": summary})
            results = [*results[:index], outcome.result.model_dump(mode="json")]
            await self._update(
                run.id,
                step_index=index + 1,
                step_log=log_list,
                results_enc=self._seal(run.id, results),
                tainted=run.tainted or outcome.untrusted,
                pending=None,
                active_s=active,
            )
            return True
        if isinstance(outcome, NeedsApproval):
            req = outcome.request
            log_list.append(
                {"index": index, "tool": tool, "status": "waiting", "summary": req.title[:MAX_SUMMARY]}
            )
            pending = Pending(
                kind="approval",
                call_id=outcome.call_id,
                step=index,
                approval_id=req.approval_id,
                title=req.title,
                summary=req.summary[:500],
                level=req.level.value,
                expires_at=req.expires_at,
            )
            await self._update(
                run.id,
                status="awaiting_approval",
                step_log=log_list,
                pending=pending.model_dump(mode="json"),
                active_s=active,
            )
            return False
        if isinstance(outcome, NeedsDeviceAction):
            log_list.append({"index": index, "tool": tool, "status": "waiting", "summary": None})
            pending = Pending(
                kind="device",
                call_id=outcome.call_id,
                step=index,
                action_id=outcome.request.action_id,
                expires_at=outcome.request.expires_at,
                request=outcome.request.model_dump(mode="json"),
            )
            await self._update(
                run.id,
                status="awaiting_device",
                step_log=log_list,
                pending=pending.model_dump(mode="json"),
                active_s=active,
            )
            return False
        if isinstance(outcome, Denied):
            await self._fail_step(run, "denied", outcome.reason, started)
            return False
        assert isinstance(outcome, Failed)
        await self._fail_step(run, "failed", outcome.error, started)
        return False

    async def _fail_step(self, run: RoutineRun, status: str, error: str, started: float) -> None:
        log_list = [
            *_settled(run.step_log, run.step_index),
            {
                "index": run.step_index,
                "tool": run.steps[run.step_index]["tool"],
                "status": status,
                "error": error,
            },
        ]
        await self._update(
            run.id,
            status="failed",
            step_log=log_list,
            error=error[:200],
            pending=None,
            finished_at=self._now(),
            active_s=run.active_s + (time.monotonic() - started),
        )

    async def _finish(self, run: RoutineRun, status: str, started: float, error: str | None = None) -> None:
        await self._update(
            run.id,
            status=status,
            error=error,
            pending=None,
            finished_at=self._now(),
            active_s=run.active_s + (time.monotonic() - started),
        )

    # ------------------------------------------------------------ resume, cancel, expiry

    async def resume(
        self,
        run_id: str,
        *,
        device_id: str | None,
        approval: ApprovalDecision | None = None,
        device_result: DeviceActionResult | None = None,
    ) -> RunOut:
        run = await self._load(run_id)
        if run.status not in ("awaiting_approval", "awaiting_device"):
            if run.status in ("completed", "failed", "cancelled", "timed_out") or run.status == "running":
                return run_out(run)  # already answered or being processed: resuming twice is harmless
            raise RunNotWaiting()
        needs_approval = run.status == "awaiting_approval"
        if (needs_approval and approval is None) or (not needs_approval and device_result is None):
            raise RunNotWaiting(
                "This run is waiting for "
                + ("an approval decision." if needs_approval else "a device result.")
            )
        pending = Pending.model_validate(run.pending)
        if not await self._claim(run_id, run.status):
            return run_out(await self._load(run_id))
        async with self._lock(run_id):
            fresh = await self._load(run_id)
            ctx = await self._ctx(fresh)
            ctx.device_id = device_id or fresh.device_id
            started = time.monotonic()
            executor = self._reg.service("tool_executor")
            if needs_approval:
                outcome = await executor.resume_with_approval(ctx, pending.call_id, approval)
            else:
                outcome = await executor.resume_with_device_result(ctx, pending.call_id, device_result)
            if isinstance(outcome, Denied) and outcome.reason in OPEN_DENIALS:
                await self._update(run_id, status=run.status)  # the request is still open: keep waiting
                return run_out(await self._load(run_id))
            results = self._unseal(fresh)
            if not await self._apply(fresh, outcome, results, started):
                return run_out(await self._load(run_id))
        return await self._advance(run_id)

    # ------------------------------------------------------------ generic approval route

    async def owns_approval(self, lookup: Any) -> bool:
        """True when `lookup` is the approval one of our runs is waiting for."""
        if not lookup.turn_id:
            return False
        async with self._sf() as session:
            run = await session.get(RoutineRun, lookup.turn_id)
        if run is None or run.status != "awaiting_approval" or not run.pending:
            return False
        return bool(Pending.model_validate(run.pending).approval_id == lookup.approval_id)

    async def decide_approval(self, decision: ApprovalDecision, device: Any, lookup: Any) -> Any:
        from app.schemas.turns import ApprovalDecisionResult

        run = await self.resume(lookup.turn_id, device_id=device.device_id, approval=decision)
        return ApprovalDecisionResult(
            approval_id=decision.approval_id,
            owner="automation",
            approved=decision.approved,
            status=run.status,
            run_id=run.id,
            result=run.model_dump(mode="json"),
        )

    async def cancel(self, run_id: str) -> RunOut:
        run = await self._load(run_id)
        if run.status in ACTIVE_STATUSES:
            await self._update(
                run_id, status="cancelled", pending=None, finished_at=self._now(), error="cancelled"
            )
            approvals = self._reg.service("approvals")
            for request in await approvals.list_pending(turn_id=run_id):
                await approvals.cancel(request.approval_id)  # nothing stays answerable for a cancelled run
        return run_out(await self._load(run_id))

    async def expire_waiting(self, routine_id: str | None = None) -> int:
        """Runs whose approval or device request has expired will never continue: fail them."""
        now = self._now()
        async with self._sf() as session:
            stmt = select(RoutineRun).where(RoutineRun.status.in_(("awaiting_approval", "awaiting_device")))
            if routine_id is not None:
                stmt = stmt.where(RoutineRun.routine_id == routine_id)
            rows = (await session.scalars(stmt)).all()
        expired = [
            r
            for r in rows
            if r.pending
            and Pending.model_validate(r.pending).expires_at
            and Pending.model_validate(r.pending).expires_at < now
        ]
        for row in expired:
            reason = "approval_expired" if row.status == "awaiting_approval" else "device_action_expired"
            await self._update(row.id, status="failed", error=reason, pending=None, finished_at=now)
        return len(expired)

    async def recover_stale(self) -> int:
        """Runs left `running` by a restart or a cancelled call are closed as timed out."""
        cutoff = self._now() - timedelta(seconds=self.limits.run_time_limit_s * 2)
        async with self._sf() as session:
            result = await session.execute(
                update(RoutineRun)
                .where(RoutineRun.status == "running", RoutineRun.updated_at < cutoff)
                .values(
                    status="timed_out", error="interrupted", finished_at=self._now(), updated_at=self._now()
                )
            )
            await session.commit()
        return int(getattr(result, "rowcount", 0) or 0)


__all__ = ["Routine", "RoutineRunner", "RunLimits"]
