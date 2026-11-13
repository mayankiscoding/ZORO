"""Graph state, per-turn limits and the shared core every supervisor node uses.

State is plain JSON (strings, numbers, lists, dicts) so any checkpointer can store it. `tainted`
only ever turns on; `results`, `queued` and `drafts` only grow; `usage` adds up.
"""

from __future__ import annotations

import inspect
import operator
from dataclasses import dataclass, field
from typing import Annotated, Any, TypedDict

from langgraph.config import get_stream_writer

from app.agents.calls import Budget, RunEnv, TurnCancelled
from app.agents.runner import AgentRunner
from app.agents.spec import AgentCatalog
from app.core.types import PrivacyMode
from app.orchestrator.store import ConversationStore


def user_message_id(turn_id: str) -> str:
    return f"msg_{turn_id.removeprefix('turn_')}u"


def assistant_message_id(turn_id: str) -> str:
    return f"msg_{turn_id.removeprefix('turn_')}a"


async def call_flexible(fn: Any, /, *args: Any, **kwargs: Any) -> Any:
    """Call an optional sibling service with the keyword arguments it accepts."""
    params = inspect.signature(fn).parameters
    if not any(p.kind is inspect.Parameter.VAR_KEYWORD for p in params.values()):
        kwargs = {key: value for key, value in kwargs.items() if key in params}
    result = fn(*args, **kwargs)
    return await result if inspect.isawaitable(result) else result


def _first(current: str | None, new: str | None) -> str | None:
    return current or new


def _add_usage(current: dict[str, int] | None, new: dict[str, int] | None) -> dict[str, int]:
    total = dict(current or {})
    for key, value in (new or {}).items():
        total[key] = total.get(key, 0) + int(value)
    return total


class TurnState(TypedDict, total=False):
    # request
    turn_id: str
    conversation_id: str
    device_id: str | None
    text: str
    modality: str
    language_hint: str | None
    privacy_mode: str
    timezone: str
    platform: str | None
    capabilities: list[str]
    app_state: dict[str, Any]
    user_initiated: bool
    length: str
    # derived
    lang: str
    killed: bool
    last_agent: str | None
    tainted: Annotated[bool, operator.or_]  # one way
    route: dict[str, Any]
    tasks: list[dict[str, Any]]  # per agent: {"agent", "mode": "plan" | "model", "calls": [...], "label"}
    recall: list[dict[str, Any]]  # {"text", "data_class", "id", "category"}
    results: Annotated[list[dict[str, Any]], operator.add]
    drafts: Annotated[list[dict[str, Any]], operator.add]
    queued: Annotated[list[dict[str, Any]], operator.add]  # calls for the actions step, in order
    cursor: int  # index of the next queued call
    pending: dict[str, Any] | None  # the call the turn is suspended on
    stop: Annotated[str | None, _first]  # the budget that ran out, if any
    usage: Annotated[dict[str, int], _add_usage]
    reply: dict[str, Any]
    message_id: str


@dataclass(frozen=True)
class TurnLimits:
    recursion_limit: int = 40  # graph supersteps per run segment
    max_tool_calls: int = 24
    max_tokens: int = 60_000
    max_seconds: float = 120.0


@dataclass
class TurnRuntime:
    """In-process companion of one running segment of a turn (not checkpointed)."""

    budget: Budget = field(default_factory=Budget)
    cancelled: bool = False

    def check_cancel(self) -> None:
        if self.cancelled:
            raise TurnCancelled()


class TurnCore:
    """Services and helpers shared by the supervisor's nodes."""

    def __init__(self, reg: Any, limits: TurnLimits | None = None) -> None:
        self.reg = reg
        self.limits = limits or TurnLimits()
        self.runtimes: dict[str, TurnRuntime] = {}

    @property
    def catalog(self) -> AgentCatalog:
        catalog: AgentCatalog = self.reg.service("agents")
        return catalog

    @property
    def runner(self) -> AgentRunner:
        runner: AgentRunner = self.reg.service("agent_runner")
        return runner

    @property
    def store(self) -> ConversationStore:
        store: ConversationStore = self.reg.service("conversations")
        return store

    def begin(self, turn_id: str, usage: dict[str, int] | None = None) -> TurnRuntime:
        """Start a run segment: budgets continue from what earlier segments of the turn used."""
        used = usage or {}
        runtime = TurnRuntime(
            budget=Budget(
                max_tool_calls=self.limits.max_tool_calls,
                max_tokens=self.limits.max_tokens,
                max_seconds=self.limits.max_seconds,
                tool_calls=int(used.get("tool_calls", 0)),
                tokens=int(used.get("input_tokens", 0)) + int(used.get("output_tokens", 0)),
                elapsed_before_s=int(used.get("elapsed_ms", 0)) / 1000,
            )
        )
        self.runtimes[turn_id] = runtime
        return runtime

    def runtime(self, turn_id: str) -> TurnRuntime:
        return self.runtimes.get(turn_id) or self.begin(turn_id)

    def end(self, turn_id: str) -> None:
        self.runtimes.pop(turn_id, None)

    async def emit(self, event: Any) -> None:
        """Send a turn event to whoever streams this graph run (LangGraph's custom stream)."""
        try:
            writer = get_stream_writer()
        except RuntimeError:
            return  # a node called outside a graph run
        writer(event)

    def env(self, state: dict[str, Any] | TurnState) -> RunEnv:
        turn_id = str(state["turn_id"])
        runtime = self.runtime(turn_id)
        return RunEnv(
            turn_id=turn_id,
            conversation_id=state.get("conversation_id"),
            device_id=state.get("device_id"),
            lang=str(state.get("lang") or "en"),
            privacy_mode=PrivacyMode(state.get("privacy_mode") or PrivacyMode.STRICT_PRIVATE.value),
            timezone=str(state.get("timezone") or "Asia/Kolkata"),
            tainted=bool(state.get("tainted", False)),
            user_initiated=bool(state.get("user_initiated", False)),
            emit=self.emit,
            budget=runtime.budget,
            check_cancel=runtime.check_cancel,
        )
