"""The route step: local intents first, a structured model call only when the local router is
unsure and a model may see the request, otherwise the personal assistant."""

from __future__ import annotations

import logging
from typing import Any, Literal

from pydantic import ValidationError

from app.agents.access import model_permitted
from app.agents.calls import PlannedCall, is_read_only, split_slots, target_from_hints
from app.agents.spec import RoutingDecision
from app.core.types import AgentId, DataClass, DevicePlatform, PrivacyMode
from app.orchestrator.router import Candidate, IntentRouter
from app.orchestrator.state import TurnCore, TurnState
from app.providers.types import ChatMessage, ChatRequest, NoPermittedModel, ProviderError
from app.schemas.turns import RouteDecided
from app.tools.intents import IntentContext, IntentSpec

log = logging.getLogger(__name__)

Engine = Literal["deterministic", "local_model", "cloud_model"]

_NOT_ROUTABLE = frozenset({AgentId.SUPERVISOR, AgentId.VOICE})
_LOW_CONFIDENCE_FLOOR = 0.5


def _plan_tasks(turn_id: str, steps: list[Candidate], *, user_initiated: bool) -> list[dict[str, Any]]:
    """Group plan steps by agent (one task per agent; an agent runs its own steps in order)."""
    tasks: dict[str, dict[str, Any]] = {}
    for index, step in enumerate(steps):
        agent = step.intent.agent
        # "_missing", "_assumptions", "_target_platform" ... are hints, not arguments. A call whose
        # slots are incomplete still runs: the tool answers with its own clarification.
        args, hints = split_slots(step.slots)
        target_device_id, target_platform = target_from_hints(hints)
        call = PlannedCall(
            call_id=f"{turn_id}.p{index}",
            agent=agent,
            tool=step.intent.tool,
            args=args,
            user_initiated=user_initiated,
            intent=step.intent.name,
            target_device_id=target_device_id,
            target_platform=target_platform,
            hints=hints,
        )
        task = tasks.setdefault(agent.value, {"agent": agent.value, "mode": "plan", "calls": [], "label": ""})
        task["calls"].append(call.to_json())
        task["label"] = ", ".join(filter(None, [task["label"], step.intent.name]))
    return list(tasks.values())


def _intent_line(intent: IntentSpec) -> str:
    examples = "; ".join(intent.examples[:2])
    return f"- {intent.name} ({intent.agent.value})" + (f": e.g. {examples}" if examples else "")


class RouteNode:
    def __init__(self, core: TurnCore) -> None:
        self._core = core

    async def intent_context(self, state: TurnState) -> IntentContext:
        reg = self._core.reg
        conversation_id = state.get("conversation_id")
        working_sets: dict[str, Any] = {}
        if conversation_id and reg.has_service("conversation_state"):
            working_sets = await reg.service("conversation_state").working_sets(conversation_id)
        platform = state.get("platform")
        last_agent = state.get("last_agent")
        return IntentContext(
            lang=state.get("lang", "en"),
            now=reg.service("clock").now(),
            timezone=state.get("timezone", "Asia/Kolkata"),
            platform=DevicePlatform(platform) if platform else None,
            capabilities=tuple(state.get("capabilities") or ()),
            app_state=dict(state.get("app_state") or {}),
            last_agent=AgentId(last_agent) if last_agent else None,
            conversation_id=conversation_id,
            working_sets=working_sets,
        )

    async def __call__(self, state: TurnState) -> dict[str, Any]:
        core = self._core
        reg = core.reg
        turn_id = state["turn_id"]
        core.runtime(turn_id).check_cancel()
        if state.get("killed"):
            route = {
                "agents": [AgentId.SECURITY.value],
                "reason": "kill switch is on",
                "engine": "deterministic",
                "data_classes": [],
            }
            await core.emit(
                RouteDecided(
                    agents=[AgentId.SECURITY], reason=route["reason"], data_classes=[], engine="deterministic"
                )
            )
            return {"tasks": [], "route": route}

        text = state["text"]
        ictx = await self.intent_context(state)
        local = IntentRouter(reg.intents, reg.tools).route(text, ictx)
        usage: dict[str, int] = {}
        engine: Engine = "deterministic"
        if local.confident:
            tasks = _plan_tasks(turn_id, list(local.steps), user_initiated=True)
            reason = local.reason
        else:
            mode = PrivacyMode(state["privacy_mode"])
            spec = core.catalog.get(AgentId.SUPERVISOR)
            decision: RoutingDecision | None = None
            if await model_permitted(reg, spec.task_class, {DataClass.PERSONAL}, mode):
                decision = await self._ask_model(state, mode, usage)
            if decision is not None:
                engine = "local_model" if mode is PrivacyMode.STRICT_PRIVATE else "cloud_model"
                tasks, reason = self._from_decision(turn_id, text, ictx, decision)
            elif (
                local.best is not None
                and local.best.confidence >= _LOW_CONFIDENCE_FLOOR
                and is_read_only(reg.tools.get(local.best.intent.tool))
            ):
                # No model to ask: a weak match is still used when it can only read.
                tasks = _plan_tasks(turn_id, [local.best], user_initiated=True)
                reason = f"best local match {local.best.intent.name}; no model permitted"
            else:
                tasks = [
                    {
                        "agent": AgentId.PERSONAL_ASSISTANT.value,
                        "mode": "model",
                        "calls": [],
                        "label": "open request",
                    }
                ]
                reason = f"{local.reason}; personal assistant"

        agents = [AgentId(task["agent"]) for task in tasks]
        classes: set[DataClass] = set()
        for task in tasks:
            for call in task["calls"]:
                tool = reg.tools.get(call["tool"])
                classes |= set(tool.data_classes) if tool is not None else set()
        data_classes = sorted(classes or {DataClass.PERSONAL}, key=lambda c: (c.rank, c.value))
        await core.emit(RouteDecided(agents=agents, reason=reason, data_classes=data_classes, engine=engine))
        route = {
            "agents": [agent.value for agent in agents],
            "reason": reason,
            "engine": engine,
            "data_classes": [c.value for c in data_classes],
        }
        return {"tasks": tasks, "route": route, "usage": usage}

    def _from_decision(
        self, turn_id: str, text: str, ictx: IntentContext, decision: RoutingDecision
    ) -> tuple[list[dict[str, Any]], str]:
        """Code validates the model's suggestion: a named intent must be registered, belong to
        the named agent, and its own extractor must accept the owner's words."""
        reg = self._core.reg
        agent = AgentId.PERSONAL_ASSISTANT if decision.agent in _NOT_ROUTABLE else decision.agent
        intent = reg.intents.get(decision.intent) if decision.intent else None
        tool = reg.tools.get(intent.tool) if intent is not None else None
        if intent is not None and tool is not None and intent.agent == agent and agent in tool.agents:
            try:
                slots = intent.extract(text, ictx)
            except Exception as exc:
                log.error(
                    "intent extractor failed", extra={"intent": intent.name, "error_type": type(exc).__name__}
                )
                slots = None
            if slots is not None:
                step = Candidate(intent, dict(slots), decision.confidence, text)
                # The model picked the intent, so its calls are not "asked for by the owner".
                return _plan_tasks(
                    turn_id, [step], user_initiated=False
                ), f"model routing: intent {intent.name}"
        task: dict[str, Any] = {"agent": agent.value, "mode": "model", "calls": [], "label": "open request"}
        return [task], f"model routing: {agent.value}"

    async def _ask_model(
        self, state: TurnState, mode: PrivacyMode, usage: dict[str, int]
    ) -> RoutingDecision | None:
        core = self._core
        spec = core.catalog.get(AgentId.SUPERVISOR)
        agents = "\n".join(
            f"- {s.id.value}: {s.role}" for s in core.catalog.all() if s.id not in _NOT_ROUTABLE
        )
        intents = "\n".join(_intent_line(intent) for intent in core.reg.intents.all())
        request = ChatRequest(
            task=spec.task_class,
            messages=(
                ChatMessage(
                    role="system",
                    content=f"{spec.system_prompt}\n\nSpecialists:\n{agents}\n\nRegistered intents:\n{intents or '- none'}",
                ),
                ChatMessage(role="user", content=state["text"]),
            ),
            response_schema=RoutingDecision.model_json_schema(),
            max_output_tokens=spec.max_tokens,
            data_classes=frozenset({DataClass.PERSONAL}),
            privacy_mode=mode,
            agent=AgentId.SUPERVISOR,
            turn_id=state["turn_id"],
            timeout_s=spec.max_seconds,
        )
        try:
            resp = await core.reg.service("gateway").chat(request)
        except (NoPermittedModel, ProviderError) as exc:
            log.info("routing model unavailable", extra={"error_type": type(exc).__name__})
            return None
        usage.update(
            model_calls=1, input_tokens=resp.usage.input_tokens, output_tokens=resp.usage.output_tokens
        )
        core.runtime(state["turn_id"]).budget.tokens += resp.usage.input_tokens + resp.usage.output_tokens
        try:
            return RoutingDecision.model_validate(resp.parsed)
        except ValidationError:
            log.warning("routing model returned an invalid decision")
            return None
