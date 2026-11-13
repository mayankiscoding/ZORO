"""Tool executor: the only way a tool runs.

Pipeline (design spec section 5): allowlist -> validate args -> policy (incl. rate limit) -> run
with timeout -> validate result -> audit -> wrap if untrusted. Calls that need the owner or a
device suspend and are resumed with `resume_with_approval` / `resume_with_device_result`, which
run exactly the arguments that were digested. The executor emits no turn events; the orchestrator
does, from the returned outcome.
"""

from __future__ import annotations

import asyncio
import logging
import time
from datetime import timedelta
from typing import Any

from pydantic import BaseModel, ValidationError

from app.core.clock import Clock, SystemClock
from app.core.errors import ApprovalExpired, ApprovalReplayed, ZoroError
from app.core.ids import new_id
from app.core.types import RiskLevel
from app.schemas.turns import ApprovalDecision, DeviceActionRequest, DeviceActionResult
from app.security.approvals import ApprovalService, action_digest
from app.security.audit import AuditDecision, AuditLog
from app.security.devices import DeviceRegistry
from app.security.policy import PolicyEngine
from app.tools import journal as j
from app.tools.dispatcher import DeviceDispatcher, DeviceNoAnswer, DeviceOffline, NullDeviceDispatcher
from app.tools.outcome import Denied, Failed, NeedsApproval, NeedsDeviceAction, ToolOutcome
from app.tools.presentation import build_completed, decode_outcome, encode_outcome, resolve_approval_view
from app.tools.registry import ToolRegistry
from app.tools.spec import ToolContext, ToolSpec
from app.tools.targeting import TargetChoice, select_target

log = logging.getLogger(__name__)

_MIN_DEVICE_WINDOW_S = 60.0
# Nothing reached a device, so the journal entry is dropped and the same call may be retried.
# `device_timeout` is deliberately absent: the action was delivered and may have run.
_NO_EFFECT_FAILURES = frozenset({"device_offline", "device_unavailable"})
_DEVICE_ERROR_CODES = frozenset(
    {"permission_denied", "unsupported", "user_cancelled", "invalid_arguments", "expired", "failed"}
)
_NO_TARGET = {
    "unknown_device": "That device is not paired with ZORO.",
    "device_revoked": "That device's access was revoked.",
    "unsupported_on_device": "That device cannot run this action.",
    "no_device": "No paired device can run this action.",
}


class ToolExecutor:
    def __init__(
        self,
        *,
        registry: ToolRegistry,
        policy: PolicyEngine,
        approvals: ApprovalService,
        audit: AuditLog,
        devices: DeviceRegistry,
        journal: j.ToolCallJournal,
        clock: Clock | None = None,
        dispatcher: DeviceDispatcher | None = None,
    ) -> None:
        self._registry = registry
        self._policy = policy
        self._approvals = approvals
        self._audit = audit
        self._devices = devices
        self._journal = journal
        self._clock = clock or SystemClock()
        self._dispatcher: DeviceDispatcher = dispatcher or NullDeviceDispatcher()

    def set_dispatcher(self, dispatcher: DeviceDispatcher) -> None:
        self._dispatcher = dispatcher

    # ------------------------------------------------------------ execute

    async def execute(self, ctx: ToolContext, tool_name: str, raw_args: Any, *, call_id: str) -> ToolOutcome:
        tool = self._registry.get(tool_name)
        if tool is None:
            await self._note(ctx, tool_name, None, "tool.policy", "denied", "unknown_tool")
            return Denied("unknown_tool", call_id=call_id, tool=tool_name)
        if ctx.agent not in tool.agents:
            await self._note(ctx, tool.name, tool, "tool.policy", "denied", "agent_not_allowed")
            return Denied("agent_not_allowed", call_id=call_id, tool=tool.name)
        try:
            args = tool.input_model.model_validate(raw_args)
        except ValidationError as exc:
            fields = sorted({".".join(str(part) for part in error["loc"]) for error in exc.errors()})
            await self._note(ctx, tool.name, tool, "tool.run", "failed", f"invalid_arguments fields={fields}")
            return Failed(
                "invalid_arguments",
                call_id=call_id,
                tool=tool.name,
                message=f"Arguments are not valid for {tool.name}: {', '.join(fields) or 'body'}",
            )
        args_json: dict[str, Any] = args.model_dump(mode="json")
        digest = action_digest(tool.name, args_json)

        record = await self._journal.load(call_id)
        if record is not None:
            return await self._reenter(ctx, tool, record, digest)

        decision = await self._policy.evaluate(tool, ctx)
        if decision.denied:
            blocked: AuditDecision = "blocked" if decision.reason == "kill_switch" else "denied"
            await self._note(ctx, tool.name, tool, "tool.policy", blocked, decision.reason)
            return Denied(decision.reason, call_id=call_id, tool=tool.name)

        new_record = j.CallRecord(
            call_id=call_id,
            turn_id=ctx.turn_id,
            tool=tool.name,
            agent=ctx.agent.value,
            device_id=ctx.device_id,
            args=args_json,
            action_digest=digest,
            state=j.RUNNING,
        )
        if decision.needs_approval:
            view = resolve_approval_view(tool, args, args_json)
            request = await self._approvals.create(
                tool=tool.name,
                args=args_json,
                risk=tool.risk,
                level=decision.level,
                title=view.title,
                summary=view.summary,
                details=view.details,
                turn_id=ctx.turn_id,
                agent=ctx.agent,
                call_id=call_id,
                device_id=ctx.device_id,
                expires_in_seconds=decision.expires_in_seconds,
                tainted=ctx.tainted,
            )
            waiting = j.CallRecord(
                **{**new_record.__dict__, "state": j.AWAITING_APPROVAL, "approval_id": request.approval_id}
            )
            if not await self._journal.begin(waiting):
                return Failed("call_in_progress", call_id=call_id, tool=tool.name, retryable=True)
            await self._note(
                ctx, tool.name, tool, "tool.approval_requested", "info",
                f"level={request.level.value} reason={decision.reason} args={sorted(args_json)}",
            )  # fmt: skip
            if ctx.emitter is None:
                # No live turn stream will show this request: tell the owner's online devices.
                await self._approvals.announce(request)
            return NeedsApproval(request, call_id=call_id, tool=tool.name)

        await self._note(ctx, tool.name, tool, "tool.policy", "allowed", decision.reason)
        journaled = tool.risk is not RiskLevel.LOW or tool.executor == "device"
        if journaled and not await self._journal.begin(new_record):
            return Failed("call_in_progress", call_id=call_id, tool=tool.name, retryable=True)
        return await self._run(ctx, tool, args, args_json, call_id, journaled=journaled)

    # ------------------------------------------------------------ resume

    async def resume_with_approval(
        self, ctx: ToolContext, call_id: str, decision: ApprovalDecision
    ) -> ToolOutcome:
        record = await self._journal.load(call_id)
        if record is None:
            return Failed("call_not_found", call_id=call_id)
        tool = self._registry.get(record.tool)
        if tool is None:
            return Failed("unknown_tool", call_id=call_id, tool=record.tool)
        if ctx.agent.value != record.agent:
            return Denied("agent_mismatch", call_id=call_id, tool=tool.name)
        if record.state == j.DONE and record.outcome is not None:
            return decode_outcome(ctx, tool, record.outcome, call_id)
        if record.state != j.AWAITING_APPROVAL or record.approval_id is None:
            return Denied("approval_replayed", call_id=call_id, tool=tool.name)
        if decision.approval_id != record.approval_id:
            return Denied("approval_mismatch", call_id=call_id, tool=tool.name)

        try:
            verdict = await self._approvals.verify(decision)
        except ZoroError as exc:
            await self._note(ctx, tool.name, tool, "approval.rejected", "denied", exc.error_code)
            outcome = Denied(exc.error_code, call_id=call_id, tool=tool.name, message=exc.message)
            if isinstance(exc, ApprovalExpired | ApprovalReplayed):
                await self._journal.finish(call_id, encode_outcome(outcome))
            return outcome  # a bad signature or digest leaves the request pending

        await self._audit.append(
            actor=verdict.device_id,
            action="approval.decided",
            decision="approved" if verdict.approved else "denied",
            tool=tool.name,
            risk=tool.risk,
            data_classes=tool.data_classes,
            detail=f"approval={verdict.approval_id} level={verdict.level.value} turn={record.turn_id}",
        )
        if not verdict.approved:
            return await self._finish(call_id, Denied("approval_declined", call_id=call_id, tool=tool.name))
        if not await self._journal.transition(call_id, j.AWAITING_APPROVAL, j.RUNNING):
            return Denied("approval_replayed", call_id=call_id, tool=tool.name)

        # Execute exactly what was digested: the stored arguments, re-hashed and compared.
        if not (action_digest(tool.name, record.args) == record.action_digest == verdict.action_digest):
            await self._note(ctx, tool.name, tool, "tool.run", "failed", "digest_mismatch")
            return await self._finish(call_id, Failed("digest_mismatch", call_id=call_id, tool=tool.name))
        gate = await self._policy.gate(tool, ctx)
        if gate.denied:
            await self._note(ctx, tool.name, tool, "tool.policy", "denied", gate.reason)
            return await self._finish(call_id, Denied(gate.reason, call_id=call_id, tool=tool.name))
        args = tool.input_model.model_validate(record.args)
        return await self._run(ctx, tool, args, record.args, call_id, journaled=True)

    async def resume_with_device_result(
        self, ctx: ToolContext, call_id: str, result: DeviceActionResult
    ) -> ToolOutcome:
        record = await self._journal.load(call_id)
        if record is None:
            return Failed("call_not_found", call_id=call_id)
        tool = self._registry.get(record.tool)
        if tool is None:
            return Failed("unknown_tool", call_id=call_id, tool=record.tool)
        if ctx.agent.value != record.agent:
            return Denied("agent_mismatch", call_id=call_id, tool=tool.name)
        if record.state == j.DONE and record.outcome is not None:
            return decode_outcome(ctx, tool, record.outcome, call_id)
        if record.state != j.AWAITING_DEVICE or record.device_request is None:
            return Failed("call_not_waiting", call_id=call_id, tool=tool.name)
        if result.action_id != record.action_id:
            return Denied("action_mismatch", call_id=call_id, tool=tool.name)
        if ctx.device_id != record.target_device_id:
            return Denied("wrong_device", call_id=call_id, tool=tool.name)
        if not await self._journal.transition(call_id, j.AWAITING_DEVICE, j.RUNNING):
            return Failed("call_in_progress", call_id=call_id, tool=tool.name, retryable=True)
        if record.device_request.expires_at <= self._clock.now():
            await self._note(ctx, tool.name, tool, "tool.run", "failed", "device_action_expired")
            return await self._finish(
                call_id, Failed("device_action_expired", call_id=call_id, tool=tool.name)
            )
        gate = await self._policy.gate(tool, ctx)
        if gate.denied:
            await self._note(ctx, tool.name, tool, "tool.policy", "denied", gate.reason)
            return await self._finish(call_id, Denied(gate.reason, call_id=call_id, tool=tool.name))
        outcome = await self._complete_device(ctx, tool, result, call_id, time.monotonic())
        return await self._finish(call_id, outcome)

    # ------------------------------------------------------------ internals

    async def _reenter(
        self, ctx: ToolContext, tool: ToolSpec, record: j.CallRecord, digest: str
    ) -> ToolOutcome:
        """`execute` called again with a known `call_id` (graph code re-runs on resume)."""
        call_id = record.call_id
        if record.tool != tool.name or record.action_digest != digest or record.agent != ctx.agent.value:
            return Failed("call_id_conflict", call_id=call_id, tool=tool.name)
        if record.state == j.DONE and record.outcome is not None:
            return decode_outcome(ctx, tool, record.outcome, call_id)
        if record.state == j.AWAITING_APPROVAL and record.approval_id is not None:
            status = await self._approvals.status(record.approval_id)
            request = await self._approvals.get(record.approval_id) if status == "pending" else None
            if request is not None:
                return NeedsApproval(request, call_id=call_id, tool=tool.name)
            reason = "approval_expired" if status == "expired" else "approval_replayed"
            return await self._finish(call_id, Denied(reason, call_id=call_id, tool=tool.name))
        if record.state == j.AWAITING_DEVICE and record.device_request is not None:
            if record.device_request.expires_at <= self._clock.now():
                failed = Failed("device_action_expired", call_id=call_id, tool=tool.name)
                return await self._finish(call_id, failed)
            return NeedsDeviceAction(record.device_request, call_id=call_id, tool=tool.name)
        return Failed("call_in_progress", call_id=call_id, tool=tool.name, retryable=True)

    async def _finish(self, call_id: str, outcome: ToolOutcome) -> ToolOutcome:
        await self._journal.finish(call_id, encode_outcome(outcome))
        return outcome

    async def _run(
        self, ctx: ToolContext, tool: ToolSpec, args: BaseModel, args_json: dict[str, Any], call_id: str,
        *, journaled: bool,
    ) -> ToolOutcome:  # fmt: skip
        if tool.executor == "device":
            outcome = await self._run_device(ctx, tool, args_json, call_id)
            if isinstance(outcome, NeedsDeviceAction):
                return outcome
        else:
            outcome = await self._run_backend(ctx, tool, args, call_id)
        if not journaled:
            return outcome
        if isinstance(outcome, Failed) and outcome.error in _NO_EFFECT_FAILURES:
            await self._journal.discard(call_id)  # nothing reached a device: the call may be retried
            return outcome
        return await self._finish(call_id, outcome)

    async def _run_backend(
        self, ctx: ToolContext, tool: ToolSpec, args: BaseModel, call_id: str
    ) -> ToolOutcome:
        if tool.handler is None:  # the registry refuses this; kept as a guard
            return Failed("tool_error", call_id=call_id, tool=tool.name)
        started = time.monotonic()
        try:
            raw = await asyncio.wait_for(tool.handler(ctx, args), timeout=tool.timeout_s)
        except TimeoutError:
            await self._note(ctx, tool.name, tool, "tool.run", "failed", f"timeout after {tool.timeout_s}s")
            return Failed("timeout", call_id=call_id, tool=tool.name, retryable=True)
        except ZoroError as exc:
            await self._note(ctx, tool.name, tool, "tool.run", "failed", exc.error_code)
            return Failed(
                exc.error_code, call_id=call_id, tool=tool.name, message=exc.message, retryable=exc.retryable
            )
        except Exception as exc:
            log.error("tool raised", extra={"tool": tool.name, "error_type": type(exc).__name__})
            await self._note(ctx, tool.name, tool, "tool.run", "failed", f"tool_error {type(exc).__name__}")
            return Failed("tool_error", call_id=call_id, tool=tool.name, message="The tool failed to run.")
        return await self._complete(ctx, tool, raw, call_id, started)

    async def _complete(
        self, ctx: ToolContext, tool: ToolSpec, raw: Any, call_id: str, started: float
    ) -> ToolOutcome:
        try:
            if isinstance(raw, tool.output_model):
                result = raw
            else:
                payload = raw.model_dump() if isinstance(raw, BaseModel) else raw
                result = tool.output_model.model_validate(payload)
        except ValidationError:
            await self._note(ctx, tool.name, tool, "tool.run", "failed", "invalid_result")
            return Failed(
                "invalid_result", call_id=call_id, tool=tool.name,
                message="The tool returned data that does not match its contract.",
            )  # fmt: skip
        duration_ms = int((time.monotonic() - started) * 1000)
        await self._note(
            ctx, tool.name, tool, "tool.run", "allowed",
            f"ok duration_ms={duration_ms}" + (" untrusted_output" if tool.untrusted_output else ""),
        )  # fmt: skip
        return build_completed(ctx, tool, result, call_id, duration_ms)

    # ------------------------------------------------------------ device tools

    async def _pick_device(self, ctx: ToolContext, tool: ToolSpec) -> TargetChoice:
        """Explicit device, else the platform the owner named, else the requesting device, else
        the most recently seen online device that can run the tool (`app.tools.targeting`)."""
        return select_target(
            await self._devices.list(include_revoked=True),
            tool_name=tool.name,
            platforms=tool.device_platforms,
            is_online=self._dispatcher.is_online,
            requesting_device_id=ctx.device_id,
            explicit_device_id=ctx.target_device_id,
            platform=ctx.target_platform,
        )

    async def _run_device(
        self, ctx: ToolContext, tool: ToolSpec, args_json: dict[str, Any], call_id: str
    ) -> ToolOutcome:
        choice = await self._pick_device(ctx, tool)
        target = choice.device
        if target is None:
            problem = choice.problem or "no_device"
            await self._note(ctx, tool.name, tool, "tool.run", "failed", f"device_unavailable {problem}")
            return Failed("device_unavailable", call_id=call_id, tool=tool.name, message=_NO_TARGET[problem])
        is_requester = target.id == ctx.device_id
        window = max(tool.timeout_s, _MIN_DEVICE_WINDOW_S) if is_requester else tool.timeout_s
        request = DeviceActionRequest(
            action_id=new_id("act"),
            turn_id=ctx.turn_id,
            target_device_id=target.id,
            tool=tool.name,
            args=args_json,
            risk=tool.risk,
            requires_user_confirmation=False,  # the policy engine already decided; approvals are separate
            expires_at=self._clock.now() + timedelta(seconds=window),
        )
        if is_requester:
            if not await self._journal.await_device(call_id, j.RUNNING, request):
                return Failed("call_in_progress", call_id=call_id, tool=tool.name, retryable=True)
            await self._note(ctx, tool.name, tool, "tool.device_requested", "info", f"target={target.id}")
            return NeedsDeviceAction(request, call_id=call_id, tool=tool.name)

        started = time.monotonic()
        try:
            result = await asyncio.wait_for(
                self._dispatcher.dispatch(target.id, request, tool.timeout_s), timeout=tool.timeout_s + 2
            )
        except (DeviceNoAnswer, TimeoutError):
            # Delivered, no answer: the device may have acted. Recorded as an unknown outcome and
            # kept in the journal, so this call is never run again automatically.
            await self._note(
                ctx,
                tool.name,
                tool,
                "tool.run",
                "failed",
                f"device_timeout outcome_unknown target={target.id}",
            )
            return Failed(
                "device_timeout", call_id=call_id, tool=tool.name, retryable=False,
                message=f"{target.name} did not confirm in time. It may have run; check the device.",
            )  # fmt: skip
        except DeviceOffline:
            await self._note(ctx, tool.name, tool, "tool.run", "failed", f"device_offline target={target.id}")
            return Failed(
                "device_offline", call_id=call_id, tool=tool.name, retryable=True,
                message=f"{target.name} is not connected right now.",
            )  # fmt: skip
        if result.action_id != request.action_id:
            await self._note(ctx, tool.name, tool, "tool.run", "failed", "action_mismatch")
            return Failed("action_mismatch", call_id=call_id, tool=tool.name)
        return await self._complete_device(ctx, tool, result, call_id, started)

    async def _complete_device(
        self, ctx: ToolContext, tool: ToolSpec, result: DeviceActionResult, call_id: str, started: float
    ) -> ToolOutcome:
        if not result.ok:
            # The device contract's codes; anything else a device sends is recorded as "failed".
            code = result.error_code if result.error_code in _DEVICE_ERROR_CODES else "failed"
            await self._note(ctx, tool.name, tool, "tool.run", "failed", f"device:{code}")
            return Failed(code, call_id=call_id, tool=tool.name, message=result.error_message or "")
        return await self._complete(ctx, tool, result.result or {}, call_id, started)

    # ------------------------------------------------------------ audit

    async def _note(
        self, ctx: ToolContext, tool_name: str, tool: ToolSpec | None, action: str,
        decision: AuditDecision, detail: str,
    ) -> None:  # fmt: skip
        await self._audit.append(
            actor=ctx.agent.value,
            action=action,
            decision=decision,
            tool=tool_name[:200],
            risk=tool.risk if tool is not None else None,
            data_classes=tool.data_classes if tool is not None else (),
            detail=f"{detail} turn={ctx.turn_id} device={ctx.device_id or 'system'}",
        )
