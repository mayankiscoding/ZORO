"""TurnService: runs turns through the supervisor graph and streams `TurnEvent`s.

A turn runs in its own task and pushes events to a queue the caller reads, so a dropped connection
does not stop an approved action half way: the turn finishes and the reply is in history.
Registered as service ``turn_service``.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator
from typing import Any, Literal

from langchain_core.runnables import RunnableConfig
from langgraph.errors import GraphRecursionError
from langgraph.types import Command

from app.agents.calls import TurnCancelled
from app.core.errors import BadRequest, Conflict, KillSwitchActive, ZoroError
from app.core.types import PrivacyMode, TurnStatus
from app.orchestrator import texts
from app.orchestrator.checkpoint import CheckpointerHandle
from app.orchestrator.language import detect_language
from app.orchestrator.store import ConversationStore
from app.orchestrator.supervisor import Supervisor
from app.schemas.turns import (
    ApprovalDecision,
    ApprovalDecisionResult,
    ApprovalRequest,
    ApprovalRequired,
    DeviceActionEvent,
    DeviceActionRequest,
    ResumeRequest,
    TurnError,
    TurnRequest,
    TurnStarted,
    TurnSuspended,
)
from app.security.sessions import AuthedDevice

log = logging.getLogger(__name__)

_LENGTHS = ("brief", "balanced", "detailed")
_PURGE_EVERY_S = 3600.0
_FINAL = (TurnStatus.COMPLETED, TurnStatus.FAILED, TurnStatus.CANCELLED)


class TurnService:
    def __init__(
        self, reg: Any, supervisor: Supervisor, store: ConversationStore, checkpoints: CheckpointerHandle
    ) -> None:
        self._reg = reg
        self._supervisor = supervisor
        self._store = store
        self._checkpoints = checkpoints
        self._tasks: dict[str, asyncio.Task[None]] = {}
        self._last_purge: float | None = None

    # ------------------------------------------------------------ lifecycle

    async def startup(self) -> None:
        self._supervisor.compile(await self._checkpoints.open())
        await self.purge_expired()

    async def shutdown(self) -> None:
        tasks = [task for task in self._tasks.values() if not task.done()]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        await self._checkpoints.close()

    async def _ready(self) -> None:
        try:
            _ = self._supervisor.graph
        except RuntimeError:
            await self.startup()

    def _config(self, turn_id: str) -> RunnableConfig:
        return {
            "configurable": {"thread_id": turn_id},
            "recursion_limit": self._supervisor.core.limits.recursion_limit,
        }

    # ------------------------------------------------------------ start

    async def start(
        self, request: TurnRequest, device: AuthedDevice | None = None, *, user_initiated: bool = True
    ) -> AsyncIterator[Any]:
        """Validate, create the turn and return its event stream. Errors raised here (unknown
        conversation, kill switch) happen before any event is sent."""
        await self._ready()
        if await self._reg.service("kill_switch").is_on():
            raise KillSwitchActive()
        # A client may ask for a stricter mode for this turn, never a looser one.
        mode: PrivacyMode = await self._reg.service("privacy_state").effective_mode(request.privacy_mode)
        device_id = device.device_id if device is not None else None
        conversation_id = await self._store.ensure_conversation(
            request.conversation_id, first_text=request.input.text, device_id=device_id
        )
        lang = detect_language(request.input.text, request.input.language_hint)
        turn_id = await self._store.create_turn(
            conversation_id=conversation_id, device_id=device_id, privacy_mode=mode, language=lang
        )
        await self._purge_if_due()
        wanted = request.client.app_state.get("response_length")
        length = (
            wanted if wanted in _LENGTHS else ("brief" if request.input.modality == "voice" else "balanced")
        )
        state: dict[str, Any] = {
            "turn_id": turn_id,
            "conversation_id": conversation_id,
            "device_id": device_id,
            "text": request.input.text,
            "modality": request.input.modality,
            "language_hint": request.input.language_hint,
            "privacy_mode": mode.value,
            "timezone": request.client.timezone,
            "platform": (device.platform if device is not None else request.client.platform).value,
            "capabilities": list(request.client.capabilities or (device.capabilities if device else ())),
            "app_state": dict(request.client.app_state),
            "user_initiated": user_initiated,
            "length": length,
            "tainted": False,
        }
        lead = [TurnStarted(turn_id=turn_id, conversation_id=conversation_id, privacy_mode=mode)]
        return self._stream(turn_id, state, lead, {}, lang)

    # ------------------------------------------------------------ resume

    async def resume(
        self, turn_id: str, request: ResumeRequest, device: AuthedDevice | None = None
    ) -> AsyncIterator[Any]:
        await self._ready()
        if await self._reg.service("kill_switch").is_on():
            raise KillSwitchActive()
        if (request.approval is None) == (request.device_result is None):
            raise BadRequest("Send exactly one of approval or device_result.", code="resume_invalid")
        turn = await self._store.get_turn(turn_id)
        if turn.status is not TurnStatus.SUSPENDED:
            raise Conflict(
                f"This turn is {turn.status.value}, not waiting for an answer.", code="turn_not_suspended"
            )
        if request.approval is not None:
            kind, ref = "approval", request.approval.approval_id
        else:
            assert request.device_result is not None
            kind, ref = "device_action", request.device_result.action_id
        if kind != turn.pending_kind or ref != turn.pending_ref:
            raise Conflict("This answer does not match what the turn is waiting for.", code="resume_mismatch")
        snapshot = await self._supervisor.graph.aget_state(self._config(turn_id))
        if not snapshot.next:
            await self._store.update_turn(turn_id, status=TurnStatus.FAILED, error_code="turn_state_lost")
            raise Conflict("The saved state of this turn is gone. Ask again.", code="turn_state_lost")
        if not await self._store.claim_turn(turn_id, TurnStatus.SUSPENDED, TurnStatus.RUNNING):
            raise Conflict("This turn is already being resumed.", code="turn_not_suspended")
        usage = dict(snapshot.values.get("usage") or {})
        usage["elapsed_ms"] = int(turn.usage.get("elapsed_ms", 0))
        # The owner may have tightened the privacy mode while the turn waited: never run looser
        # than the server's mode now, and never looser than the turn started with.
        mode: PrivacyMode = await self._reg.service("privacy_state").effective_mode(turn.privacy_mode)
        answer = {
            "device_id": device.device_id if device is not None else turn.device_id,
            "privacy_mode": mode.value,
            "approval": request.approval.model_dump(mode="json") if request.approval is not None else None,
            "device_result": request.device_result.model_dump(mode="json")
            if request.device_result is not None
            else None,
        }
        return self._stream(turn_id, Command(resume=answer), [], usage, turn.language)

    # ------------------------------------------------------------ cancel

    async def cancel(self, turn_id: str) -> TurnStatus:
        """Stop a running turn, or abandon a suspended one. Finished turns are left as they are."""
        turn = await self._store.get_turn(turn_id)
        if turn.status in _FINAL:
            return turn.status
        task = self._tasks.get(turn_id)
        if task is not None and not task.done():
            runtime = self._supervisor.core.runtimes.get(turn_id)
            if runtime is not None:
                runtime.cancelled = True
            task.cancel()
            await asyncio.wait({task}, timeout=10)
            return (await self._store.get_turn(turn_id)).status
        await self._store.update_turn(turn_id, status=TurnStatus.CANCELLED, error_code="cancelled")
        await self._checkpoints.delete_threads([turn_id])
        await self._withdraw_approvals(turn_id)
        return TurnStatus.CANCELLED

    async def _withdraw_approvals(self, turn_id: str) -> None:
        """A cancelled or abandoned turn takes its pending approval requests with it, so nothing
        stays listed (or answerable) for a turn that can no longer run."""
        approvals = self._reg.service("approvals")
        for request in await approvals.list_pending(turn_id=turn_id):
            await approvals.cancel(request.approval_id)

    # ------------------------------------------------------------ approvals (generic route)

    async def owns_approval(self, lookup: Any) -> bool:
        """True when `lookup` is the approval a suspended turn of ours is waiting for."""
        if not lookup.turn_id:
            return False
        try:
            turn = await self._store.get_turn(lookup.turn_id)
        except ZoroError:
            return False
        return (
            turn.status is TurnStatus.SUSPENDED
            and turn.pending_kind == "approval"
            and turn.pending_ref == lookup.approval_id
        )

    async def decide_approval(
        self, decision: ApprovalDecision, device: AuthedDevice, lookup: Any
    ) -> ApprovalDecisionResult:
        """`POST /v1/approvals/{id}/decision` for a suspended turn: resume it and return what
        happened, with the resumed turn's events in order."""
        stream = await self.resume(lookup.turn_id, ResumeRequest(approval=decision), device)
        events = [event async for event in stream]
        kinds = [getattr(event, "type", "") for event in events]
        status = (
            "completed"
            if "turn_completed" in kinds
            else "suspended"
            if "turn_suspended" in kinds
            else "failed"
        )
        return ApprovalDecisionResult(
            approval_id=decision.approval_id,
            owner="turn",
            approved=decision.approved,
            status=status,
            turn_id=lookup.turn_id,
            events=[event.model_dump(mode="json") for event in events],
        )

    # ------------------------------------------------------------ conversations

    async def delete_conversation(self, conversation_id: str) -> None:
        turn_ids = await self._store.delete_conversation(conversation_id)
        await self._forget([conversation_id], turn_ids)

    async def purge_expired(self) -> int:
        """Retention: drop conversations older than the owner's setting (memory preferences,
        `PUT /v1/memory/settings`); `ZORO_CONVERSATION_RETENTION_DAYS` is only the default."""
        self._last_purge = time.monotonic()
        days = await self.retention_days()
        conversation_ids, turn_ids = await self._store.purge_older_than(days)
        await self._forget(conversation_ids, turn_ids)
        return len(conversation_ids)

    async def retention_days(self) -> int:
        default = int(self._reg.service("settings").conversation_retention_days)
        if not self._reg.has_service("memory"):
            return default
        prefs = getattr(self._reg.service("memory"), "prefs", None)
        read = getattr(prefs, "conversation_retention_days", None)
        if read is None:
            return default
        try:
            return int(await read())
        except Exception as exc:  # the preference store is optional: keep the configured default
            log.warning("retention preference unavailable", extra={"error_type": type(exc).__name__})
            return default

    async def _purge_if_due(self) -> None:
        if self._last_purge is None or time.monotonic() - self._last_purge >= _PURGE_EVERY_S:
            try:
                await self.purge_expired()
            except Exception as exc:  # housekeeping never fails a turn
                log.warning("retention purge failed", extra={"error_type": type(exc).__name__})

    async def _forget(self, conversation_ids: list[str], turn_ids: list[str]) -> None:
        for turn_id in turn_ids:
            task = self._tasks.get(turn_id)
            if task is not None and not task.done():
                task.cancel()
        if self._reg.has_service("conversation_state"):
            for conversation_id in conversation_ids:
                await self._reg.service("conversation_state").delete(conversation_id)
        await self._checkpoints.delete_threads(turn_ids)

    # ------------------------------------------------------------ running

    async def _stream(
        self, turn_id: str, graph_input: Any, lead: list[Any], usage: dict[str, int], lang: str
    ) -> AsyncIterator[Any]:
        queue: asyncio.Queue[Any] = asyncio.Queue()
        for event in lead:
            queue.put_nowait(event)
        self._supervisor.core.begin(turn_id, usage)
        self._tasks[turn_id] = asyncio.create_task(self._drive(turn_id, graph_input, queue, lang))
        while True:
            event = await queue.get()
            if event is None:
                return
            yield event

    async def _drive(self, turn_id: str, graph_input: Any, queue: asyncio.Queue[Any], lang: str) -> None:
        core = self._supervisor.core
        interrupts: list[Any] = []
        try:
            async for mode, chunk in self._supervisor.graph.astream(
                graph_input,
                self._config(turn_id),
                stream_mode=["custom", "updates"],
            ):
                if mode == "custom":
                    queue.put_nowait(chunk)
                elif isinstance(chunk, dict) and "__interrupt__" in chunk:
                    interrupts = list(chunk["__interrupt__"])
            if interrupts:
                await self._suspend(turn_id, interrupts[0].value, queue)
            else:
                await self._checkpoints.delete_threads([turn_id])  # finished: nothing left to resume
        except GraphRecursionError:
            await self._fail(turn_id, queue, "recursion_limit", texts.budget_message("recursion_limit", lang))
        except (TurnCancelled, asyncio.CancelledError):
            await self._store.update_turn(turn_id, status=TurnStatus.CANCELLED, error_code="cancelled")
            await self._checkpoints.delete_threads([turn_id])
            await self._withdraw_approvals(turn_id)
            queue.put_nowait(TurnError(code="cancelled", message=texts.say(lang, texts.CANCELLED)))
        except Exception as exc:
            log.error("turn failed", extra={"turn_id": turn_id, "error_type": type(exc).__name__})
            await self._fail(
                turn_id, queue, "internal_error", "Something went wrong on the ZORO server.", retryable=True
            )
        finally:
            core.end(turn_id)
            self._tasks.pop(turn_id, None)
            queue.put_nowait(None)

    async def _fail(
        self, turn_id: str, queue: asyncio.Queue[Any], code: str, message: str, *, retryable: bool = False
    ) -> None:
        await self._store.update_turn(turn_id, status=TurnStatus.FAILED, error_code=code)
        await self._checkpoints.delete_threads([turn_id])
        queue.put_nowait(TurnError(code=code, message=message, retryable=retryable))

    async def _suspend(self, turn_id: str, payload: dict[str, Any], queue: asyncio.Queue[Any]) -> None:
        """The graph stopped at `interrupt()`: tell the device what it is waiting for."""
        elapsed_ms = int(self._supervisor.core.runtime(turn_id).budget.elapsed_s() * 1000)
        reason: Literal["approval", "device_action"]
        if payload.get("kind") == "approval":
            approval = ApprovalRequest.model_validate(payload["request"])
            queue.put_nowait(ApprovalRequired(approval=approval))
            ref, reason = approval.approval_id, "approval"
        else:
            action = DeviceActionRequest.model_validate(payload["request"])
            queue.put_nowait(DeviceActionEvent(action=action))
            ref, reason = action.action_id, "device_action"
        await self._store.update_turn(
            turn_id,
            status=TurnStatus.SUSPENDED,
            pending_kind=reason,
            pending_ref=ref,
            usage={"elapsed_ms": elapsed_ms},
        )
        queue.put_nowait(TurnSuspended(turn_id=turn_id, reason=reason))
