"""Temporary conversation state: small JSON values keyed by conversation, with an expiry.

This is the "temporary conversation state" memory tier. Its main use is the *working set*: the
items last shown to the owner (products, contacts, emails, photos …) in display order, so that a
follow-up such as "add the second one" / "doosra wala" resolves to the right item instead of a
guess. Values are sealed at rest and expire; nothing here is long-term memory.
"""

from __future__ import annotations

import json
from datetime import timedelta
from typing import TYPE_CHECKING, Any

from sqlalchemy import delete, select

from app.core.clock import Clock
from app.security.crypto import FieldCipher
from app.tools.models import ConversationStateRow

if TYPE_CHECKING:
    from app.db.session import SessionFactory

DEFAULT_TTL_S = 6 * 60 * 60
MAX_VALUE_BYTES = 64 * 1024
_WORKING_SET = "working_set:"


class ConversationStateTooLarge(ValueError):
    """A value above MAX_VALUE_BYTES: keep references here, not documents."""


class ConversationStateStore:
    """Registered as service ``conversation_state``; reachable from tools as ``ctx.state``."""

    def __init__(self, session_factory: SessionFactory, cipher: FieldCipher, clock: Clock) -> None:
        self._sessions = session_factory
        self._cipher = cipher
        self._clock = clock

    @staticmethod
    def _aad(conversation_id: str, key: str) -> str:
        return f"conversation_state|{conversation_id}|{key}"

    async def get(self, conversation_id: str, key: str) -> Any | None:
        async with self._sessions() as session:
            row = await session.get(ConversationStateRow, (conversation_id, key))
            if row is None or row.expires_at <= self._clock.now():
                return None
            return json.loads(self._cipher.decrypt_str(row.value_enc, aad=self._aad(conversation_id, key)))

    async def put(self, conversation_id: str, key: str, value: Any, *, ttl_s: int = DEFAULT_TTL_S) -> None:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)
        if len(payload.encode()) > MAX_VALUE_BYTES:
            raise ConversationStateTooLarge(f"{key}: {len(payload)} bytes")
        now = self._clock.now()
        sealed = self._cipher.encrypt(payload, aad=self._aad(conversation_id, key))
        async with self._sessions() as session:
            row = await session.get(ConversationStateRow, (conversation_id, key))
            if row is None:
                session.add(
                    ConversationStateRow(
                        conversation_id=conversation_id,
                        key=key,
                        value_enc=sealed,
                        updated_at=now,
                        expires_at=now + timedelta(seconds=ttl_s),
                    )
                )
            else:
                row.value_enc = sealed
                row.updated_at = now
                row.expires_at = now + timedelta(seconds=ttl_s)
            await session.commit()

    async def delete(self, conversation_id: str, key: str | None = None) -> None:
        """Remove one key, or everything for the conversation when `key` is None."""
        stmt = delete(ConversationStateRow).where(ConversationStateRow.conversation_id == conversation_id)
        if key is not None:
            stmt = stmt.where(ConversationStateRow.key == key)
        async with self._sessions() as session:
            await session.execute(stmt)
            await session.commit()

    async def working_set(self, conversation_id: str, kind: str) -> list[dict[str, Any]]:
        """Items last shown for `kind` (e.g. "products"), in the order the owner saw them."""
        value = await self.get(conversation_id, _WORKING_SET + kind)
        return list(value) if isinstance(value, list) else []

    async def set_working_set(
        self, conversation_id: str, kind: str, items: list[dict[str, Any]], *, ttl_s: int = DEFAULT_TTL_S
    ) -> None:
        await self.put(conversation_id, _WORKING_SET + kind, items, ttl_s=ttl_s)

    async def working_sets(self, conversation_id: str) -> dict[str, list[dict[str, Any]]]:
        """Every live working set of the conversation, keyed by kind (used to build IntentContext)."""
        now = self._clock.now()
        async with self._sessions() as session:
            rows = (
                await session.scalars(
                    select(ConversationStateRow).where(
                        ConversationStateRow.conversation_id == conversation_id,
                        ConversationStateRow.key.like(_WORKING_SET + "%"),
                        ConversationStateRow.expires_at > now,
                    )
                )
            ).all()
        result: dict[str, list[dict[str, Any]]] = {}
        for row in rows:
            value = json.loads(
                self._cipher.decrypt_str(row.value_enc, aad=self._aad(conversation_id, row.key))
            )
            if isinstance(value, list):
                result[row.key.removeprefix(_WORKING_SET)] = value
        return result

    async def purge_expired(self) -> int:
        async with self._sessions() as session:
            result = await session.execute(
                delete(ConversationStateRow).where(ConversationStateRow.expires_at <= self._clock.now())
            )
            await session.commit()
            return int(getattr(result, "rowcount", 0) or 0)
