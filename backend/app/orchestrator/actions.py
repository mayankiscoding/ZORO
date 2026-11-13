"""The actions step: queued calls (anything that is not a read-only backend tool) run one at a
time through the executor. A call that needs the owner's approval or a result from the requesting
device parks in `pending`, and `await_owner` suspends the turn with `interrupt()`.

`await_owner` begins with `interrupt()`: on resume the node re-runs from the top, and nothing
above the interrupt has a side effect. Everything after it is idempotent per `call_id`.
"""

from __future__ import annotations

import logging
from typing import Any

from langgraph.types import interrupt

from app.agents.calls import (
    PlannedCall,
    emit_finished,
    execute_call,
    follow_up_calls,
    record_of,
    resolve_follow_up,
    skipped_record,
    tool_context,
)
from app.agents.security import explain_reason
from app.orchestrator.state import TurnCore, TurnState
from app.schemas.turns import ApprovalDecision, DeviceActionResult, TurnError
from app.tools.outcome import Denied, Failed, NeedsApproval, NeedsDeviceAction, ToolOutcome

log = logging.getLogger(__name__)

#: Answers the executor rejects without consuming the suspended call: the owner may try again.
_MAY_STILL_WAIT = frozenset(
    {
        "invalid_signature",
        "approval_digest_mismatch",
        "approval_mismatch",
        "action_mismatch",
        "wrong_device",
        "resume_mismatch",
    }
)


def _pending(call: PlannedCall, outcome: NeedsApproval | NeedsDeviceAction) -> dict[str, Any]:
    kind = "approval" if isinstance(outcome, NeedsApproval) else "device_action"
    return {"kind": kind, "call": call.to_json(), "request": outcome.request.model_dump(mode="json")}


class ActionNodes:
    def __init__(self, core: TurnCore) -> None:
        self._core = core

    # ------------------------------------------------------------ actions

    async def actions(self, state: TurnState) -> dict[str, Any]:
        core = self._core
        runtime = core.runtime(state["turn_id"])
        runtime.check_cancel()
        queued = state.get("queued") or []
        cursor = int(state.get("cursor") or 0)
        if state.get("killed") or state.get("stop") or cursor >= len(queued):
            return {}
        exceeded = runtime.budget.exceeded()
        if exceeded is not None or not runtime.budget.take_tool_call():
            return {"stop": exceeded or "tool_calls"}
        planned = PlannedCall.from_json(queued[cursor])
        # A follow-up takes arguments from the step before it. When that step did not complete,
        # this one is skipped: recorded, never run, and it costs no tool call.
        call = resolve_follow_up(planned, list(state.get("results") or []))
        if call is None:
            runtime.budget.tool_calls -= 1
            return {"results": [{**skipped_record(planned), "phase": "action"}], "cursor": cursor + 1}
        outcome, ctx = await execute_call(core.reg, core.env(state), call)
        update: dict[str, Any] = {"usage": {"tool_calls": 1}, "tainted": ctx.tainted}
        if isinstance(outcome, NeedsApproval | NeedsDeviceAction):
            update["pending"] = _pending(call, outcome)
        else:
            update.update(self._finished(call, outcome))
            update["cursor"] = cursor + 1
        return update

    @staticmethod
    def _finished(call: PlannedCall, outcome: ToolOutcome) -> dict[str, Any]:
        """State update for a final outcome: its record, plus the follow-ups it handed over
        (queued like any other call, so they pass the executor and the policy engine)."""
        record = {**record_of(call, outcome), "phase": "action"}
        update: dict[str, Any] = {"results": [record]}
        steps = follow_up_calls(call, record["follow_ups"])
        if steps:
            update["queued"] = [step.to_json() for step in steps]
        return update

    def after_actions(self, state: TurnState) -> str:
        if state.get("pending"):
            return "await_owner"
        more = int(state.get("cursor") or 0) < len(state.get("queued") or [])
        if more and not state.get("stop") and not state.get("killed"):
            return "actions"
        return "synthesize"

    # ------------------------------------------------------------ await_owner

    async def await_owner(self, state: TurnState) -> dict[str, Any]:
        pending = state.get("pending") or {}
        # Side-effect free up to here: this line re-runs when the turn resumes.
        answer: dict[str, Any] = interrupt({"kind": pending.get("kind"), "request": pending.get("request")})

        core = self._core
        core.runtime(state["turn_id"]).check_cancel()
        call = PlannedCall.from_json(pending["call"])
        device_id = answer.get("device_id") or state.get("device_id")  # a turn may resume from another device
        privacy_mode = answer.get("privacy_mode") or state.get("privacy_mode")  # may have been tightened
        env = core.env({**state, "device_id": device_id, "privacy_mode": privacy_mode})
        ctx = tool_context(core.reg, env, call)
        executor = core.reg.service("tool_executor")

        outcome: ToolOutcome
        if pending["kind"] == "approval" and answer.get("approval"):
            decision = ApprovalDecision.model_validate(answer["approval"])
            outcome = await executor.resume_with_approval(ctx, call.call_id, decision)
        elif pending["kind"] == "device_action" and answer.get("device_result"):
            result = DeviceActionResult.model_validate(answer["device_result"])
            outcome = await executor.resume_with_device_result(ctx, call.call_id, result)
        else:
            outcome = Failed("resume_mismatch", call_id=call.call_id, tool=call.tool)

        update: dict[str, Any] = {
            "device_id": device_id,
            "privacy_mode": privacy_mode,
            "tainted": ctx.tainted,
        }
        code = (
            outcome.reason
            if isinstance(outcome, Denied)
            else outcome.error
            if isinstance(outcome, Failed)
            else ""
        )
        if code in _MAY_STILL_WAIT:
            # The executor is the source of truth on whether the call is still waiting (a wrong
            # signature or a mismatched answer leaves it pending). Re-entry is idempotent.
            again = await executor.execute(ctx, call.tool, call.args, call_id=call.call_id)
            if isinstance(again, NeedsApproval | NeedsDeviceAction):
                await core.emit(TurnError(code=code, message=explain_reason(code, env.lang), retryable=True))
                update["pending"] = _pending(call, again)
                return update
            outcome = again  # it stopped waiting meanwhile (for example the approval expired)
        if isinstance(outcome, NeedsApproval | NeedsDeviceAction):
            update["pending"] = _pending(call, outcome)  # e.g. approved, and now the device must act
            return update
        await emit_finished(env, call, outcome)
        update["pending"] = None
        update.update(self._finished(call, outcome))
        update["cursor"] = int(state.get("cursor") or 0) + 1
        return update

    def after_await(self, state: TurnState) -> str:
        return "await_owner" if state.get("pending") else "actions"
