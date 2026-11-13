"""Conversation persistence: conversations, messages, turns, history pages and retention purge."""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import and_, delete, or_, select

from app.core.clock import Clock
from app.core.errors import BadRequest, NotFound
from app.core.ids import new_id
from app.core.types import AgentId, PrivacyMode, TurnStatus
from app.db.session import SessionFactory
from app.orchestrator.models import ConversationRow, MessageRow, TurnRow
from app.schemas.common import Page, UICard
from app.schemas.data import ConversationSummary, Message
from app.security.crypto import FieldCipher

_TITLE_CHARS = 60
_PREVIEW_CHARS = 140


@dataclass(frozen=True)
class TurnRecord:
    id: str
    conversation_id: str
    device_id: str | None
    status: TurnStatus
    privacy_mode: PrivacyMode
    language: str
    pending_kind: str | None
    pending_ref: str | None
    error_code: str | None
    message_id: str | None
    usage: dict[str, Any]


def _clip(text: str, limit: int) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 1] + "…"


def _encode_cursor(*parts: str) -> str:
    return base64.urlsafe_b64encode("|".join(parts).encode()).decode("ascii")


def _decode_cursor(cursor: str, count: int) -> list[str]:
    try:
        parts = base64.urlsafe_b64decode(cursor.encode("ascii")).decode().split("|")
    except (binascii.Error, ValueError, UnicodeDecodeError):
        raise BadRequest("The cursor is not valid.", code="invalid_cursor") from None
    if len(parts) != count:
        raise BadRequest("The cursor is not valid.", code="invalid_cursor")
    return parts


class ConversationStore:
    """Registered as service ``conversations``."""

    def __init__(self, session_factory: SessionFactory, cipher: FieldCipher, clock: Clock) -> None:
        self._sf = session_factory
        self._cipher = cipher
        self._clock = clock
        self._write = asyncio.Lock()  # message sequence numbers are assigned one at a time

    def _seal(self, text: str, row_id: str, column: str) -> str:
        return self._cipher.encrypt(text, aad=f"orchestrator|{row_id}|{column}")

    def _open(self, token: str, row_id: str, column: str) -> str:
        return self._cipher.decrypt_str(token, aad=f"orchestrator|{row_id}|{column}")

    # ------------------------------------------------------------ conversations

    async def ensure_conversation(
        self, conversation_id: str | None, *, first_text: str, device_id: str | None
    ) -> str:
        """Return the id of an existing conversation, or create one titled from the first words."""
        async with self._sf() as session:
            if conversation_id is not None:
                if await session.get(ConversationRow, conversation_id) is None:
                    raise NotFound("This conversation does not exist.", code="conversation_not_found")
                return conversation_id
            new = new_id("conv")
            now = self._clock.now()
            session.add(
                ConversationRow(
                    id=new,
                    title_enc=self._seal(_clip(first_text, _TITLE_CHARS) or "New conversation", new, "title"),
                    preview_enc=self._seal("", new, "preview"),
                    message_count=0,
                    created_by_device_id=device_id,
                    created_at=now,
                    updated_at=now,
                )
            )
            await session.commit()
            return new

    async def last_agent(self, conversation_id: str) -> AgentId | None:
        async with self._sf() as session:
            row = await session.get(ConversationRow, conversation_id)
        if row is None or not row.last_agent:
            return None
        try:
            return AgentId(row.last_agent)
        except ValueError:
            return None

    async def list_conversations(
        self, *, cursor: str | None = None, limit: int = 20
    ) -> Page[ConversationSummary]:
        limit = max(1, min(limit, 100))
        stmt = select(ConversationRow).order_by(ConversationRow.updated_at.desc(), ConversationRow.id.desc())
        if cursor:
            stamp, last_id = _decode_cursor(cursor, 2)
            try:
                moment = datetime.fromisoformat(stamp)
            except ValueError:
                raise BadRequest("The cursor is not valid.", code="invalid_cursor") from None
            stmt = stmt.where(
                or_(
                    ConversationRow.updated_at < moment,
                    and_(ConversationRow.updated_at == moment, ConversationRow.id < last_id),
                )
            )
        async with self._sf() as session:
            rows = list((await session.scalars(stmt.limit(limit + 1))).all())
        page = rows[:limit]
        items = [
            ConversationSummary(
                id=row.id,
                title=self._open(row.title_enc, row.id, "title"),
                updated_at=row.updated_at,
                last_message_preview=self._open(row.preview_enc, row.id, "preview"),
                message_count=row.message_count,
            )
            for row in page
        ]
        more = len(rows) > limit
        next_cursor = _encode_cursor(page[-1].updated_at.isoformat(), page[-1].id) if more and page else None
        return Page[ConversationSummary](items=items, next_cursor=next_cursor)

    async def delete_conversation(self, conversation_id: str) -> list[str]:
        """Delete a conversation with its messages and turns. Returns the turn ids removed, so
        the caller can drop their checkpoints and temporary state."""
        async with self._sf() as session:
            if await session.get(ConversationRow, conversation_id) is None:
                raise NotFound("This conversation does not exist.", code="conversation_not_found")
            turn_ids = await self._delete(session, [conversation_id])
            await session.commit()
        return turn_ids

    async def _delete(self, session: Any, conversation_ids: list[str]) -> list[str]:
        turn_ids = list(
            (
                await session.scalars(select(TurnRow.id).where(TurnRow.conversation_id.in_(conversation_ids)))
            ).all()
        )
        await session.execute(delete(MessageRow).where(MessageRow.conversation_id.in_(conversation_ids)))
        await session.execute(delete(TurnRow).where(TurnRow.conversation_id.in_(conversation_ids)))
        await session.execute(delete(ConversationRow).where(ConversationRow.id.in_(conversation_ids)))
        return turn_ids

    async def purge_older_than(self, days: int) -> tuple[list[str], list[str]]:
        """Retention: remove conversations not touched for `days`. Returns (conversation ids, turn ids)."""
        if days <= 0:
            return [], []
        cutoff = self._clock.now() - timedelta(days=days)
        async with self._sf() as session:
            ids = list(
                (
                    await session.scalars(
                        select(ConversationRow.id).where(ConversationRow.updated_at < cutoff)
                    )
                ).all()
            )
            if not ids:
                return [], []
            turn_ids = await self._delete(session, ids)
            await session.commit()
        return ids, turn_ids

    # ------------------------------------------------------------ messages

    async def add_message(
        self,
        *,
        message_id: str,
        conversation_id: str,
        turn_id: str | None,
        role: str,
        text: str,
        language: str,
        agents: list[str] | None = None,
        cards: list[dict[str, Any]] | None = None,
        data_classes: list[str] | None = None,
    ) -> str:
        """Insert a message once: a repeated `message_id` is a no-op (graph nodes may re-run)."""
        now = self._clock.now()
        async with self._write, self._sf() as session:
            if await session.get(MessageRow, message_id) is not None:
                return message_id
            conversation = await session.get(ConversationRow, conversation_id)
            if conversation is None:
                raise NotFound("This conversation does not exist.", code="conversation_not_found")
            conversation.message_count += 1
            conversation.updated_at = now
            conversation.preview_enc = self._seal(_clip(text, _PREVIEW_CHARS), conversation_id, "preview")
            if role == "assistant" and agents:
                conversation.last_agent = agents[0]
            session.add(
                MessageRow(
                    id=message_id,
                    conversation_id=conversation_id,
                    turn_id=turn_id,
                    seq=conversation.message_count,
                    role=role,
                    text_enc=self._seal(text, message_id, "text"),
                    cards_enc=self._seal(json.dumps(cards), message_id, "cards") if cards else None,
                    language=language,
                    agents=list(agents or []),
                    data_classes=list(data_classes or []),
                    created_at=now,
                )
            )
            await session.commit()
        return message_id

    async def list_messages(
        self, conversation_id: str, *, cursor: str | None = None, limit: int = 50
    ) -> Page[Message]:
        """Oldest first. `cursor` is the position after the last message of the previous page."""
        limit = max(1, min(limit, 200))
        after = 0
        if cursor:
            (raw,) = _decode_cursor(cursor, 1)
            if not raw.isdigit():
                raise BadRequest("The cursor is not valid.", code="invalid_cursor")
            after = int(raw)
        async with self._sf() as session:
            if await session.get(ConversationRow, conversation_id) is None:
                raise NotFound("This conversation does not exist.", code="conversation_not_found")
            rows = list(
                (
                    await session.scalars(
                        select(MessageRow)
                        .where(MessageRow.conversation_id == conversation_id, MessageRow.seq > after)
                        .order_by(MessageRow.seq)
                        .limit(limit + 1)
                    )
                ).all()
            )
        page = rows[:limit]
        items = [
            Message(
                id=row.id,
                role="assistant" if row.role == "assistant" else "user",
                text=self._open(row.text_enc, row.id, "text"),
                language=row.language,
                created_at=row.created_at,
                agents=[AgentId(a) for a in row.agents or [] if a in AgentId._value2member_map_],
                cards=[
                    UICard.model_validate(c) for c in json.loads(self._open(row.cards_enc, row.id, "cards"))
                ]
                if row.cards_enc
                else [],
            )
            for row in page
        ]
        next_cursor = _encode_cursor(str(page[-1].seq)) if len(rows) > limit and page else None
        return Page[Message](items=items, next_cursor=next_cursor)

    # ------------------------------------------------------------ turns

    async def create_turn(
        self, *, conversation_id: str, device_id: str | None, privacy_mode: PrivacyMode, language: str
    ) -> str:
        turn_id = new_id("turn")
        now = self._clock.now()
        async with self._sf() as session:
            session.add(
                TurnRow(
                    id=turn_id,
                    conversation_id=conversation_id,
                    device_id=device_id,
                    status=TurnStatus.RUNNING.value,
                    privacy_mode=privacy_mode.value,
                    language=language,
                    usage={},
                    created_at=now,
                    updated_at=now,
                )
            )
            await session.commit()
        return turn_id

    async def get_turn(self, turn_id: str) -> TurnRecord:
        async with self._sf() as session:
            row = await session.get(TurnRow, turn_id)
        if row is None:
            raise NotFound("This turn does not exist.", code="turn_not_found")
        return TurnRecord(
            id=row.id,
            conversation_id=row.conversation_id,
            device_id=row.device_id,
            status=TurnStatus(row.status),
            privacy_mode=PrivacyMode(row.privacy_mode),
            language=row.language,
            pending_kind=row.pending_kind,
            pending_ref=row.pending_ref,
            error_code=row.error_code,
            message_id=row.message_id,
            usage=dict(row.usage or {}),
        )

    async def update_turn(self, turn_id: str, *, status: TurnStatus, **fields: Any) -> None:
        """Set the status and any of: pending_kind, pending_ref, error_code, message_id, usage, language."""
        async with self._sf() as session:
            row = await session.get(TurnRow, turn_id)
            if row is None:
                return
            row.status = status.value
            if status is not TurnStatus.SUSPENDED:
                row.pending_kind = None
                row.pending_ref = None
            for key, value in fields.items():
                setattr(row, key, value)
            row.updated_at = self._clock.now()
            await session.commit()

    async def claim_turn(self, turn_id: str, expected: TurnStatus, new: TurnStatus) -> bool:
        """Atomic status change, so one suspended turn is resumed by one request only."""
        from sqlalchemy import update

        async with self._sf() as session:
            result = await session.execute(
                update(TurnRow)
                .where(TurnRow.id == turn_id, TurnRow.status == expected.value)
                .values(status=new.value, updated_at=self._clock.now())
            )
            await session.commit()
        return int(getattr(result, "rowcount", 0) or 0) == 1
