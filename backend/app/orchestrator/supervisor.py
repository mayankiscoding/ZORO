"""The supervisor graph (design spec section 7):

    ingest -> route -> recall -> work (one `agent` node per selected agent, in parallel, read-only)
           -> actions (queued calls, one at a time) <-> await_owner (interrupt for an approval or
           a device result) -> synthesize -> remember -> finish

Every node but `await_owner` runs once. `await_owner` starts with `interrupt()`, so nothing
before it has a side effect when the node re-runs on resume.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

from langgraph.checkpoint.base import BaseCheckpointSaver
from langgraph.graph import END, START, StateGraph
from langgraph.graph.state import CompiledStateGraph
from langgraph.types import Send

from app.agents.calls import PlannedCall
from app.agents.runner import AgentRun
from app.core.types import AgentId, DataClass, TurnStatus
from app.orchestrator.actions import ActionNodes
from app.orchestrator.finish import FinishNodes
from app.orchestrator.language import detect_language
from app.orchestrator.routing import RouteNode
from app.orchestrator.state import TurnCore, TurnLimits, TurnState, user_message_id
from app.schemas.turns import AgentFinished, AgentStarted

log = logging.getLogger(__name__)

RECALL_LIMIT = 5


def _recall_item(item: Any) -> dict[str, Any] | None:
    """Normalise a recalled memory (a model or a mapping) and label it with its data class."""
    data = (
        item.model_dump(mode="json")
        if hasattr(item, "model_dump")
        else dict(item)
        if isinstance(item, dict)
        else None
    )
    if not data or not data.get("text"):
        return None
    raw = data.get("sensitivity") or data.get("data_class") or DataClass.PERSONAL.value
    try:
        data_class = DataClass(raw)
    except ValueError:
        data_class = DataClass.SENSITIVE  # an unknown label is never treated as harmless
    if data_class is DataClass.SECRET:
        return None
    return {
        "id": str(data.get("id", "")),
        "text": str(data["text"]),
        "data_class": data_class.value,
        "category": str(data.get("category", "")),
    }


class Supervisor:
    """Builds and owns the compiled graph. Registered as service ``supervisor``."""

    def __init__(self, reg: Any, limits: TurnLimits | None = None) -> None:
        self.core = TurnCore(reg, limits)
        self._route = RouteNode(self.core)
        self._actions = ActionNodes(self.core)
        self._finish = FinishNodes(self.core)
        self._graph: CompiledStateGraph[Any, Any, Any, Any] | None = None

    # ------------------------------------------------------------ graph

    def compile(self, checkpointer: BaseCheckpointSaver[Any]) -> CompiledStateGraph[Any, Any, Any, Any]:
        graph: StateGraph[Any, Any, Any, Any] = StateGraph(TurnState)
        graph.add_node("ingest", self.ingest)
        graph.add_node("route", self._route)
        graph.add_node("recall", self.recall)
        graph.add_node("agent", self.agent)  # type: ignore[arg-type]  # receives the Send payload
        graph.add_node("actions", self._actions.actions)
        graph.add_node("await_owner", self._actions.await_owner)
        graph.add_node("synthesize", self._finish.synthesize)
        graph.add_node("remember", self._finish.remember)
        graph.add_node("finish", self._finish.finish)
        graph.add_edge(START, "ingest")
        graph.add_edge("ingest", "route")
        graph.add_edge("route", "recall")
        graph.add_conditional_edges("recall", self.dispatch, ["agent", "actions"])
        graph.add_edge("agent", "actions")
        graph.add_conditional_edges(
            "actions", self._actions.after_actions, ["await_owner", "actions", "synthesize"]
        )
        graph.add_conditional_edges("await_owner", self._actions.after_await, ["await_owner", "actions"])
        graph.add_edge("synthesize", "remember")
        graph.add_edge("remember", "finish")
        graph.add_edge("finish", END)
        self._graph = graph.compile(checkpointer=checkpointer)
        return self._graph

    @property
    def graph(self) -> CompiledStateGraph[Any, Any, Any, Any]:
        if self._graph is None:
            raise RuntimeError("the supervisor graph is not compiled yet (startup has not run)")
        return self._graph

    # ------------------------------------------------------------ nodes

    async def ingest(self, state: TurnState) -> dict[str, Any]:
        core = self.core
        turn_id = state["turn_id"]
        core.runtime(turn_id).check_cancel()
        lang = detect_language(state["text"], state.get("language_hint"))
        killed = bool(await core.reg.service("kill_switch").is_on())
        last_agent = await core.store.last_agent(state["conversation_id"])
        await core.store.add_message(
            message_id=user_message_id(turn_id),
            conversation_id=state["conversation_id"],
            turn_id=turn_id,
            role="user",
            text=state["text"],
            language=lang,
        )
        await core.store.update_turn(turn_id, status=TurnStatus.RUNNING, language=lang)
        return {
            "lang": lang,
            "killed": killed,
            "last_agent": last_agent.value if last_agent else None,
            "cursor": 0,
        }

    async def recall(self, state: TurnState) -> dict[str, Any]:
        """Memory recall through the optional service "memory"; skipped when it is absent."""
        reg = self.core.reg
        if state.get("killed") or not state.get("tasks") or not reg.has_service("memory"):
            return {"recall": []}
        self.core.runtime(state["turn_id"]).check_cancel()
        env = self.core.env(state)
        ctx = reg.tool_context(
            turn_id=env.turn_id, agent=AgentId.MEMORY, device_id=env.device_id,
            conversation_id=env.conversation_id, privacy_mode=env.privacy_mode, lang=env.lang,
            timezone=env.timezone, tainted=env.tainted, user_initiated=env.user_initiated,
        )  # fmt: skip
        try:
            found = await reg.service("memory").recall(state["text"], limit=RECALL_LIMIT, ctx=ctx)
        except Exception as exc:  # memory is optional: a failure never blocks the turn
            log.warning("memory recall failed", extra={"error_type": type(exc).__name__})
            return {"recall": []}
        items = [item for item in (_recall_item(raw) for raw in found or []) if item is not None]
        return {"recall": items[:RECALL_LIMIT]}

    def dispatch(self, state: TurnState) -> list[Send] | str:
        """Fan out: one `agent` task per selected agent, run in the same superstep."""
        tasks = state.get("tasks") or []
        if not tasks or state.get("killed"):
            return "actions"
        shared = {key: state.get(key) for key in (
            "turn_id", "conversation_id", "device_id", "text", "privacy_mode", "timezone", "lang",
            "tainted", "user_initiated", "recall",
        )}  # fmt: skip
        return [Send("agent", {**shared, "task": task}) for task in tasks]

    async def agent(self, payload: dict[str, Any]) -> dict[str, Any]:
        core = self.core
        task = payload["task"]
        agent = AgentId(task["agent"])
        spec = core.catalog.get(agent)
        env = core.env(payload)
        env.check_cancel()
        await core.emit(AgentStarted(agent=agent, task=str(task.get("label") or spec.role)))
        run = AgentRun(agent=agent)
        started = time.monotonic()
        try:
            async with asyncio.timeout(spec.max_seconds):
                if task["mode"] == "plan":
                    calls = [PlannedCall.from_json(call) for call in task["calls"]]
                    await core.runner.run_plan(env, agent, calls, run)
                else:
                    await core.runner.run_model(
                        env, agent, payload["text"], recall=payload.get("recall") or [], run=run
                    )
        except TimeoutError:
            run.stop = run.stop or "agent_timeout"
        ok = run.ok and all(record["status"] == "completed" for record in run.results)
        await core.emit(
            AgentFinished(agent=agent, ok=ok, duration_ms=int((time.monotonic() - started) * 1000))
        )
        update: dict[str, Any] = {
            "results": [{**record, "phase": "work"} for record in run.results],
            "queued": run.queued,
            "tainted": run.tainted,
            "stop": run.stop,
            "usage": {
                "model_calls": run.model_calls,
                "tool_calls": run.tool_calls,
                "input_tokens": run.input_tokens,
                "output_tokens": run.output_tokens,
            },
        }
        if task["mode"] == "model":
            update["drafts"] = [
                {
                    "agent": agent.value,
                    "text": run.text,
                    "note": run.note,
                    "data_classes": sorted(c.value for c in run.data_classes),
                }
            ]
        return update
