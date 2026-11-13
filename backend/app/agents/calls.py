"""One logical tool call from plan to outcome: stable call ids, turn events, result records.

Every call goes through `ToolExecutor`. The executor emits no turn events, so this module emits
`tool_started` / `tool_finished` / `card` from the returned outcome. Records are plain JSON so
they can live in checkpointed graph state.
"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from app.core.types import AgentId, DevicePlatform, PrivacyMode, RiskLevel
from app.schemas.turns import CardEvent, ToolFinished, ToolStarted
from app.security.taint import wrap_untrusted
from app.tools.followup import MAX_FOLLOW_UP_DEPTH, FollowUp, resolve_args
from app.tools.outcome import Completed, Denied, Failed, NeedsApproval, NeedsDeviceAction, ToolOutcome
from app.tools.spec import ToolContext, ToolSpec

Emit = Callable[[Any], Awaitable[None]]


async def _no_emit(_event: Any) -> None:
    return None


class TurnCancelled(Exception):
    """The owner cancelled the turn; stop at the next safe point."""


@dataclass
class Budget:
    """Per-turn limits, shared by every agent of the turn (single event loop, so plain counters)."""

    max_tool_calls: int = 24
    max_tokens: int = 60_000
    max_seconds: float = 120.0
    tool_calls: int = 0
    tokens: int = 0
    elapsed_before_s: float = 0.0  # time used by earlier segments of a suspended turn
    started: float = field(default_factory=time.monotonic)

    def elapsed_s(self) -> float:
        return self.elapsed_before_s + (time.monotonic() - self.started)

    def exceeded(self) -> str | None:
        """A budget that is already spent ("wall_clock" | "tokens"), or None. The tool-call
        budget is enforced by `take_tool_call`, so finishing exactly on the limit is not an error."""
        if self.elapsed_s() >= self.max_seconds:
            return "wall_clock"
        if self.tokens >= self.max_tokens:
            return "tokens"
        return None

    def take_tool_call(self) -> bool:
        if self.tool_calls >= self.max_tool_calls:
            return False
        self.tool_calls += 1
        return True


@dataclass
class RunEnv:
    """The turn facts every tool call needs. `tainted` and `user_initiated` come from the turn
    (graph state), never from model output."""

    turn_id: str
    conversation_id: str | None = None
    device_id: str | None = None
    lang: str = "en"
    privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE
    timezone: str = "Asia/Kolkata"
    tainted: bool = False
    user_initiated: bool = False
    emit: Emit = _no_emit
    budget: Budget = field(default_factory=Budget)
    check_cancel: Callable[[], None] = lambda: None


HINT_PREFIX = "_"  # slot keys starting with "_" are hints for the orchestrator, never arguments
SKIPPED = "follow_up_skipped"


@dataclass(frozen=True)
class PlannedCall:
    """One logical tool call. `call_id` is stable across execute and resume.

    A follow-up (`app.tools.followup`) is a planned call with a `parent`: the call whose result
    feeds `args_from` (argument name -> dotted path in that result) and which must have completed
    for this one to run at all. `target_*` say where a device tool should run.
    """

    call_id: str
    agent: AgentId
    tool: str
    args: dict[str, Any]
    user_initiated: bool = False  # false for calls a model chose: MEDIUM then asks for a confirm
    intent: str | None = None
    target_device_id: str | None = None
    target_platform: DevicePlatform | None = None
    parent: str | None = None  # call_id this follow-up depends on
    args_from: dict[str, str] = field(default_factory=dict)
    depth: int = 0  # 0 for a planned call, n for a follow-up n steps down
    hints: dict[str, Any] = field(default_factory=dict)  # e.g. {"missing": [...], "assumptions": [...]}

    def to_json(self) -> dict[str, Any]:
        return {
            "call_id": self.call_id,
            "agent": self.agent.value,
            "tool": self.tool,
            "args": self.args,
            "user_initiated": self.user_initiated,
            "intent": self.intent,
            "target_device_id": self.target_device_id,
            "target_platform": self.target_platform.value if self.target_platform else None,
            "parent": self.parent,
            "args_from": self.args_from,
            "depth": self.depth,
            "hints": self.hints,
        }

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> PlannedCall:
        platform = data.get("target_platform")
        return cls(
            call_id=str(data["call_id"]),
            agent=AgentId(data["agent"]),
            tool=str(data["tool"]),
            args=dict(data.get("args") or {}),
            user_initiated=bool(data.get("user_initiated", False)),
            intent=data.get("intent"),
            target_device_id=data.get("target_device_id"),
            target_platform=DevicePlatform(platform) if platform else None,
            parent=data.get("parent"),
            args_from=dict(data.get("args_from") or {}),
            depth=int(data.get("depth") or 0),
            hints=dict(data.get("hints") or {}),
        )


def split_slots(slots: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Intent slots -> (tool arguments, hints). Keys starting with "_" (`_missing`,
    `_assumptions`, `_target_platform`, `_target_device_id`, ...) are hints, not arguments."""
    args = {key: value for key, value in slots.items() if not key.startswith(HINT_PREFIX)}
    hints = {key[1:]: value for key, value in slots.items() if key.startswith(HINT_PREFIX)}
    return args, hints


def target_from_hints(hints: dict[str, Any]) -> tuple[str | None, DevicePlatform | None]:
    """An explicit device or platform named by the owner; an unknown platform word is ignored."""
    device_id = hints.get("target_device_id")
    try:
        platform = DevicePlatform(hints["target_platform"]) if hints.get("target_platform") else None
    except ValueError:
        platform = None
    return (str(device_id) if device_id else None), platform


def follow_up_calls(call: PlannedCall, follow_ups: list[dict[str, Any]]) -> list[PlannedCall]:
    """The follow-ups a completed call handed over, as ordinary planned calls.

    They run as the same agent with the same `user_initiated` flag, so the allowlist and the
    policy engine decide exactly as for any other call; the turn's taint reaches them through the
    run environment. The list is a chain: step 0 depends on `call`, step N on step N-1. Beyond
    `MAX_FOLLOW_UP_DEPTH` nothing more is planned (a tool cannot loop the turn).
    """
    if call.depth >= MAX_FOLLOW_UP_DEPTH:
        return []
    planned: list[PlannedCall] = []
    previous = call.call_id
    for index, raw in enumerate(follow_ups):
        step = FollowUp.model_validate(raw)
        planned.append(
            PlannedCall(
                call_id=f"{call.call_id}.f{index}",
                agent=call.agent,
                tool=step.tool,
                args=dict(step.args),
                user_initiated=call.user_initiated,
                intent=call.intent,
                target_device_id=step.target_device_id or call.target_device_id,
                target_platform=step.target_platform or call.target_platform,
                parent=previous,
                args_from=dict(step.args_from_previous),
                depth=call.depth + 1,
            )
        )
        previous = planned[-1].call_id
    return planned


def resolve_follow_up(call: PlannedCall, results: list[dict[str, Any]]) -> PlannedCall | None:
    """A follow-up with its arguments filled from its parent's result, or None when the parent
    did not complete or lacks a value the step needs (the step is then skipped, never guessed)."""
    if call.parent is None:
        return call
    parent = next((r for r in reversed(results) if r.get("call_id") == call.parent), None)
    if parent is None or parent.get("status") != "completed":
        return None
    try:
        args = resolve_args(call.args, call.args_from, parent.get("result"))
    except KeyError:
        return None
    return PlannedCall(**{**call.__dict__, "args": args, "args_from": {}})


def skipped_record(call: PlannedCall) -> dict[str, Any]:
    """Record of a follow-up that was not run because the step before it did not complete."""
    return {**record_of(call, Failed(SKIPPED, call_id=call.call_id, tool=call.tool)), "status": "skipped"}


def is_read_only(spec: ToolSpec | None) -> bool:
    """LOW-risk backend tools are read-only by kernel contract and may run in parallel."""
    return spec is not None and spec.risk is RiskLevel.LOW and spec.executor == "backend"


def tool_context(reg: Any, env: RunEnv, call: PlannedCall) -> ToolContext:
    ctx: ToolContext = reg.tool_context(
        turn_id=env.turn_id,
        agent=call.agent,
        device_id=env.device_id,
        conversation_id=env.conversation_id,
        privacy_mode=env.privacy_mode,
        lang=env.lang,
        timezone=env.timezone,
        tainted=env.tainted,
        user_initiated=env.user_initiated and call.user_initiated,
        emitter=env.emit,
        target_device_id=call.target_device_id,
        target_platform=call.target_platform,
    )
    return ctx


def record_of(call: PlannedCall, outcome: ToolOutcome) -> dict[str, Any]:
    """JSON record of a final outcome (kept in graph state and used for synthesis)."""
    base: dict[str, Any] = {
        "call_id": call.call_id,
        "tool": call.tool,
        "agent": call.agent.value,
        "intent": call.intent,
        "status": "failed",
        "code": "",
        "message": "",
        "summary": None,
        "data_classes": [],
        "untrusted": False,
        "result": None,
        "card": None,
        "duration_ms": 0,
        "parent": call.parent,
        "follow_ups": [],
        "external_model_allowed": True,
    }
    if isinstance(outcome, Completed):
        base.update(
            follow_ups=[step.model_dump(mode="json") for step in outcome.follow_ups],
            external_model_allowed=outcome.external_model_allowed,
            status="completed",
            summary=outcome.summary,
            data_classes=sorted(c.value for c in outcome.data_classes),
            untrusted=outcome.untrusted,
            result=outcome.result.model_dump(mode="json"),
            card=outcome.card.model_dump(mode="json") if outcome.card is not None else None,
            duration_ms=outcome.duration_ms,
        )
    elif isinstance(outcome, Denied):
        base.update(status="denied", code=outcome.reason, message=outcome.message)
    elif isinstance(outcome, Failed):
        base.update(status="failed", code=outcome.error, message=outcome.message)
    else:
        base.update(status="failed", code="suspended")
    return base


def model_text_of(record: dict[str, Any]) -> str:
    """What a model may be shown for a record: never goes in the system role."""
    import json

    if record["status"] != "completed":
        return json.dumps({"status": record["status"], "code": record["code"]})
    text = json.dumps(record["result"], ensure_ascii=False, separators=(",", ":"))
    return wrap_untrusted(text, source=record["tool"]) if record["untrusted"] else text


async def emit_finished(env: RunEnv, call: PlannedCall, outcome: ToolOutcome) -> None:
    if isinstance(outcome, Completed):
        await env.emit(
            ToolFinished(
                call_id=call.call_id, ok=True, duration_ms=outcome.duration_ms, summary=outcome.summary
            )
        )
        if outcome.card is not None:
            await env.emit(CardEvent(card=outcome.card))
    elif isinstance(outcome, Denied):
        await env.emit(ToolFinished(call_id=call.call_id, ok=False, duration_ms=0, summary=outcome.reason))
    elif isinstance(outcome, Failed):
        await env.emit(ToolFinished(call_id=call.call_id, ok=False, duration_ms=0, summary=outcome.error))


async def execute_call(reg: Any, env: RunEnv, call: PlannedCall) -> tuple[ToolOutcome, ToolContext]:
    """Run one call through the executor and emit its events. A suspension (`NeedsApproval`,
    `NeedsDeviceAction`) emits only `tool_started`; the caller finishes it after the resume."""
    spec: ToolSpec | None = reg.tools.get(call.tool)
    ctx = tool_context(reg, env, call)
    if spec is not None:
        await env.emit(ToolStarted(call_id=call.call_id, tool=call.tool, agent=call.agent, risk=spec.risk))
    outcome: ToolOutcome = await reg.service("tool_executor").execute(
        ctx, call.tool, call.args, call_id=call.call_id
    )
    if spec is not None and not isinstance(outcome, NeedsApproval | NeedsDeviceAction):
        await emit_finished(env, call, outcome)
    return outcome, ctx
