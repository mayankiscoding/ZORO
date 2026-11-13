"""The last three steps: synthesize the reply, let memory propose what to remember, and finish
(persist the message and usage, audit, emit `turn_completed`)."""

from __future__ import annotations

import logging
import re
from decimal import Decimal
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.exc import SQLAlchemyError

from app.agents.access import external_allowed
from app.agents.security import explain_reason
from app.core.types import AgentId, DataClass, PrivacyMode, TurnStatus
from app.orchestrator.state import TurnCore, TurnState, assistant_message_id, call_flexible
from app.orchestrator.synthesis import Reply, restricted, synthesize
from app.schemas.turns import TextDelta, TurnCompleted, UsageSummary

log = logging.getLogger(__name__)

_SENTENCE_END = re.compile(r"(?<=[.!?।])\s+")


def sentence_chunks(text: str) -> list[str]:
    """Split a reply into sentences so the device can start speaking the first one early."""
    parts = [part for part in _SENTENCE_END.split(text.strip()) if part]
    return [part + (" " if index < len(parts) - 1 else "") for index, part in enumerate(parts)]


class FinishNodes:
    def __init__(self, core: TurnCore) -> None:
        self._core = core

    async def synthesize(self, state: TurnState) -> dict[str, Any]:
        core = self._core
        runtime = core.runtime(state["turn_id"])
        runtime.check_cancel()
        lang = state.get("lang", "en")
        if state.get("killed"):
            reply = Reply(text=explain_reason("kill_switch", lang), data_classes=[DataClass.PUBLIC.value])
        else:
            reply = await synthesize(
                core.reg,
                core.catalog,
                turn_id=state["turn_id"],
                lang=lang,
                mode=PrivacyMode(state["privacy_mode"]),
                user_text=state["text"],
                results=list(state.get("results") or []),
                drafts=list(state.get("drafts") or []),
                recall=list(state.get("recall") or []),
                length=str(state.get("length") or "brief"),
                stop=state.get("stop"),
                budget=runtime.budget,
            )
        for chunk in sentence_chunks(reply.text):
            await core.emit(TextDelta(text=chunk))
        return {
            "reply": {
                "text": reply.text,
                "engine": reply.engine,
                "data_classes": reply.data_classes,
                "guard_rejected": reply.guard_rejected,
            },
            "usage": {
                "model_calls": reply.model_calls,
                "input_tokens": reply.input_tokens,
                "output_tokens": reply.output_tokens,
            },
        }

    async def remember(self, state: TurnState) -> dict[str, Any]:
        """The memory package proposes memories from the turn (sensitive ones land in its review
        queue). Skipped when the service is absent, under the kill switch, and for tainted turns:
        text that came from outside is not a source of memories."""
        reg = self._core.reg
        if state.get("killed") or state.get("tainted") or not reg.has_service("memory"):
            return {}
        propose = getattr(reg.service("memory"), "propose_from_turn", None)
        if propose is None:
            return {}
        env = self._core.env(state)
        reply = state.get("reply") or {}
        ctx = reg.tool_context(
            turn_id=env.turn_id, agent=AgentId.MEMORY, device_id=env.device_id,
            conversation_id=env.conversation_id, privacy_mode=env.privacy_mode, lang=env.lang,
            timezone=env.timezone, tainted=env.tainted, user_initiated=env.user_initiated,
        )  # fmt: skip
        try:
            await call_flexible(
                propose,
                turn_id=env.turn_id,
                conversation_id=env.conversation_id,
                user_text=state["text"],
                assistant_text=reply.get("text", ""),
                lang=env.lang,
                data_classes=[DataClass(c) for c in reply.get("data_classes") or []],
                ctx=ctx,
            )
        except Exception as exc:  # optional step: never fails the turn
            log.warning("memory proposal failed", extra={"error_type": type(exc).__name__})
        return {}

    async def _cost_usd(self, turn_id: str, model_calls: int) -> Decimal:
        """Exact cost of the turn's model calls from the gateway's usage events (integer micro-USD)."""
        if model_calls <= 0:
            return Decimal("0")
        try:
            from app.providers.models import UsageEvent
        except ImportError:
            return Decimal("0")
        try:
            async with self._core.reg.service("session_factory")() as session:
                micro = await session.scalar(
                    select(func.coalesce(func.sum(UsageEvent.cost_micro_usd), 0)).where(
                        UsageEvent.turn_id == turn_id
                    )
                )
        except SQLAlchemyError:
            return Decimal("0")
        return Decimal(int(micro or 0)) / Decimal(1_000_000)

    async def finish(self, state: TurnState) -> dict[str, Any]:
        core = self._core
        reg = core.reg
        turn_id = state["turn_id"]
        runtime = core.runtime(turn_id)
        runtime.check_cancel()
        reply = state.get("reply") or {}
        route = state.get("route") or {}
        results = state.get("results") or []
        lang = state.get("lang", "en")
        classes = [DataClass(c) for c in reply.get("data_classes") or [DataClass.PERSONAL.value]]
        mode = PrivacyMode(state["privacy_mode"])
        message_id = await core.store.add_message(
            message_id=assistant_message_id(turn_id),
            conversation_id=state["conversation_id"],
            turn_id=turn_id,
            role="assistant",
            text=str(reply.get("text", "")),
            language=lang,
            agents=list(route.get("agents") or []),
            cards=[record["card"] for record in results if record.get("card")],
            data_classes=[c.value for c in classes],
        )
        used = state.get("usage") or {}
        model_calls = int(used.get("model_calls", 0))
        usage = UsageSummary(
            model_calls=model_calls,
            tool_calls=int(used.get("tool_calls", 0)),
            input_tokens=int(used.get("input_tokens", 0)),
            output_tokens=int(used.get("output_tokens", 0)),
            cost_usd=await self._cost_usd(turn_id, model_calls),
            duration_ms=int(runtime.budget.elapsed_s() * 1000),
        )
        await core.store.update_turn(
            turn_id,
            status=TurnStatus.COMPLETED,
            message_id=message_id,
            usage=usage.model_dump(mode="json"),
            error_code=state.get("stop"),
        )
        await reg.service("audit").append(
            actor=AgentId.SUPERVISOR.value,
            action="turn.completed",
            decision="info",
            data_classes=classes,
            detail=(
                f"turn={turn_id} agents={','.join(route.get('agents') or [])} route={route.get('engine', '')} "
                f"reply={reply.get('engine', '')} tools={usage.tool_calls} models={usage.model_calls} "
                f"tainted={bool(state.get('tainted'))} stop={state.get('stop') or '-'}"
            ),
        )
        await core.emit(
            TurnCompleted(
                turn_id=turn_id,
                message_id=message_id,
                language=lang,
                data_classes=classes,
                # The app may hand this reply to a cloud voice only when the same data could go
                # to an external provider in the current mode; otherwise it speaks on device.
                cloud_voice_allowed=not restricted(list(results))
                and await external_allowed(reg, mode, classes),
                usage=usage,
            )
        )
        return {"message_id": message_id}
