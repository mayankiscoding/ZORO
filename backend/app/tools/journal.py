"""Persistence for the executor: suspended calls and recorded outcomes, encrypted at rest.

The journal is what lets a suspended turn survive a restart and what makes `call_id` idempotent:
re-entering `execute` with a known `call_id` returns the same suspension or the recorded outcome
instead of running a side effect twice (the orchestrator's graph re-runs code on resume).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from sqlalchemy import delete, update
from sqlalchemy.exc import IntegrityError

from app.core.clock import Clock, SystemClock
from app.core.ids import canonical_json
from app.db.session import SessionFactory, affected_rows
from app.schemas.turns import DeviceActionRequest
from app.security.crypto import FieldCipher
from app.tools.models import ToolCallRow

AWAITING_APPROVAL = "awaiting_approval"
AWAITING_DEVICE = "awaiting_device"
RUNNING = "running"
DONE = "done"

_RETENTION = timedelta(hours=24)


@dataclass(frozen=True)
class CallRecord:
    call_id: str
    turn_id: str
    tool: str
    agent: str
    device_id: str | None
    args: dict[str, Any]  # exactly what was digested
    action_digest: str
    state: str
    approval_id: str | None = None
    action_id: str | None = None
    target_device_id: str | None = None
    device_request: DeviceActionRequest | None = None
    outcome: dict[str, Any] | None = None


class ToolCallJournal:
    def __init__(
        self, session_factory: SessionFactory, cipher: FieldCipher, clock: Clock | None = None
    ) -> None:
        self._sf = session_factory
        self._cipher = cipher
        self._clock = clock or SystemClock()

    def _seal(self, call_id: str, value: Any) -> str:
        return self._cipher.encrypt(canonical_json(value), aad=call_id)

    def _open(self, call_id: str, token: str) -> Any:
        return json.loads(self._cipher.decrypt_str(token, aad=call_id))

    def _record(self, row: ToolCallRow) -> CallRecord:
        request = (
            DeviceActionRequest.model_validate(self._open(row.call_id, row.device_request_enc))
            if row.device_request_enc
            else None
        )
        return CallRecord(
            call_id=row.call_id,
            turn_id=row.turn_id,
            tool=row.tool,
            agent=row.agent,
            device_id=row.device_id,
            args=self._open(row.call_id, row.args_enc),
            action_digest=row.action_digest,
            state=row.state,
            approval_id=row.approval_id,
            action_id=row.action_id,
            target_device_id=row.target_device_id,
            device_request=request,
            outcome=self._open(row.call_id, row.outcome_enc) if row.outcome_enc else None,
        )

    async def load(self, call_id: str) -> CallRecord | None:
        async with self._sf() as session:
            row = await session.get(ToolCallRow, call_id)
            return self._record(row) if row is not None else None

    async def begin(self, record: CallRecord) -> bool:
        """Insert a new call. False when the `call_id` is already journaled (somebody else has it)."""
        now = self._clock.now()
        async with self._sf() as session:
            await session.execute(delete(ToolCallRow).where(ToolCallRow.created_at < now - _RETENTION))
            session.add(
                ToolCallRow(
                    call_id=record.call_id,
                    turn_id=record.turn_id,
                    tool=record.tool,
                    agent=record.agent,
                    device_id=record.device_id,
                    args_enc=self._seal(record.call_id, record.args),
                    action_digest=record.action_digest,
                    state=record.state,
                    approval_id=record.approval_id,
                    action_id=record.action_id,
                    target_device_id=record.target_device_id,
                    device_request_enc=(
                        self._seal(record.call_id, record.device_request.model_dump(mode="json"))
                        if record.device_request is not None
                        else None
                    ),
                    created_at=now,
                    updated_at=now,
                )
            )
            try:
                await session.commit()
            except IntegrityError:
                await session.rollback()
                return False
        return True

    async def transition(self, call_id: str, from_state: str, to_state: str) -> bool:
        """Atomic state change; False when the call was not in `from_state` (lost a race, replay)."""
        async with self._sf() as session:
            result = await session.execute(
                update(ToolCallRow)
                .where(ToolCallRow.call_id == call_id, ToolCallRow.state == from_state)
                .values(state=to_state, updated_at=self._clock.now())
            )
            await session.commit()
            return affected_rows(result) == 1

    async def await_device(self, call_id: str, from_state: str, request: DeviceActionRequest) -> bool:
        async with self._sf() as session:
            result = await session.execute(
                update(ToolCallRow)
                .where(ToolCallRow.call_id == call_id, ToolCallRow.state == from_state)
                .values(
                    state=AWAITING_DEVICE,
                    action_id=request.action_id,
                    target_device_id=request.target_device_id,
                    device_request_enc=self._seal(call_id, request.model_dump(mode="json")),
                    updated_at=self._clock.now(),
                )
            )
            await session.commit()
            return affected_rows(result) == 1

    async def discard(self, call_id: str) -> None:
        """Forget a call that provably had no effect, so the same `call_id` can be tried again."""
        async with self._sf() as session:
            await session.execute(delete(ToolCallRow).where(ToolCallRow.call_id == call_id))
            await session.commit()

    async def finish(self, call_id: str, outcome: dict[str, Any]) -> None:
        """Record the final outcome (any state -> done)."""
        async with self._sf() as session:
            await session.execute(
                update(ToolCallRow)
                .where(ToolCallRow.call_id == call_id)
                .values(state=DONE, outcome_enc=self._seal(call_id, outcome), updated_at=self._clock.now())
            )
            await session.commit()
