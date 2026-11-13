"""Draft store: the lifecycle draft -> sent | handed_off | discarded."""

from __future__ import annotations

import hashlib

from sqlalchemy import select

from app.communications.models import MessageDraftRow
from app.communications.schemas import DraftView
from app.core.clock import Clock
from app.core.errors import Conflict, NotFound
from app.db.session import SessionFactory
from app.security.crypto import FieldCipher

_OPEN = "draft"


def _aad(draft_id: str, field: str) -> str:
    return f"communications_draft|{draft_id}|{field}"


class DraftStore:
    def __init__(self, session_factory: SessionFactory, cipher: FieldCipher, clock: Clock) -> None:
        self._sf = session_factory
        self._cipher = cipher
        self._clock = clock

    # ------------------------------------------------------------ mapping

    def _view(self, row: MessageDraftRow) -> DraftView:
        subject = row.subject_enc
        return DraftView.model_validate(
            {
                "id": row.id,
                "channel": row.channel,
                "recipient_ref": row.recipient_ref,
                "recipient_display": row.recipient_display,
                "recipient_address": self._cipher.decrypt_str(row.address_enc, aad=_aad(row.id, "address")),
                "subject": None
                if subject is None
                else self._cipher.decrypt_str(subject, aad=_aad(row.id, "subject")),
                "text": self._cipher.decrypt_str(row.text_enc, aad=_aad(row.id, "text")),
                "language": row.language,
                "status": row.status,
                "external_id": row.external_id,
                "created_at": row.created_at,
                "updated_at": row.updated_at,
                "sent_at": row.sent_at,
            }
        )

    # ------------------------------------------------------------ create

    async def create(
        self,
        *,
        channel: str,
        recipient_ref: str | None,
        recipient_display: str,
        address: str,
        text: str,
        language: str,
        subject: str | None = None,
        scope: str = "",
        conversation_id: str | None = None,
    ) -> DraftView:
        """Idempotent for the same content in the same turn or conversation (a LOW tool may re-run):
        the id is a hash of `scope` and the content, and an open draft with that id is returned as is."""
        base = f"{scope}|{channel}|{address}|{subject or ''}|{text}"
        async with self._sf() as session:
            for attempt in range(20):
                draft_id = "drf_" + hashlib.sha256(f"{base}|{attempt}".encode()).hexdigest()[:24]
                row = await session.get(MessageDraftRow, draft_id)
                if row is None:
                    break
                if row.status == _OPEN:
                    return self._view(row)
            else:
                raise Conflict("Too many identical drafts.")
            now = self._clock.now()
            row = MessageDraftRow(
                id=draft_id,
                channel=channel,
                recipient_ref=recipient_ref,
                recipient_display=recipient_display,
                address_enc=self._cipher.encrypt(address, aad=_aad(draft_id, "address")),
                subject_enc=None
                if subject is None
                else self._cipher.encrypt(subject, aad=_aad(draft_id, "subject")),
                text_enc=self._cipher.encrypt(text, aad=_aad(draft_id, "text")),
                language=language,
                status=_OPEN,
                conversation_id=conversation_id,
                created_at=now,
                updated_at=now,
            )
            session.add(row)
            await session.commit()
            return self._view(row)

    # ------------------------------------------------------------ read

    async def find(self, draft_id: str) -> DraftView | None:
        async with self._sf() as session:
            row = await session.get(MessageDraftRow, draft_id)
            return None if row is None else self._view(row)

    async def get(self, draft_id: str) -> DraftView:
        view = await self.find(draft_id)
        if view is None:
            raise NotFound("That draft does not exist.", code="draft_not_found")
        return view

    async def list_drafts(
        self, *, status: str | None = None, channel: str | None = None, limit: int = 50, offset: int = 0
    ) -> tuple[list[DraftView], int | None]:
        stmt = select(MessageDraftRow).order_by(MessageDraftRow.created_at.desc(), MessageDraftRow.id)
        if status:
            stmt = stmt.where(MessageDraftRow.status == status)
        if channel:
            stmt = stmt.where(MessageDraftRow.channel == channel)
        async with self._sf() as session:
            rows = (await session.scalars(stmt.offset(offset).limit(limit + 1))).all()
        more = len(rows) > limit
        return [self._view(r) for r in rows[:limit]], (offset + limit if more else None)

    # ------------------------------------------------------------ lifecycle

    async def edit(self, draft_id: str, *, text: str | None, subject: str | None) -> DraftView:
        async with self._sf() as session:
            row = await session.get(MessageDraftRow, draft_id)
            if row is None:
                raise NotFound("That draft does not exist.", code="draft_not_found")
            if row.status != _OPEN:
                raise Conflict("Only an open draft can be edited.", code="draft_not_open")
            if text is not None:
                row.text_enc = self._cipher.encrypt(text, aad=_aad(draft_id, "text"))
            if subject is not None:
                row.subject_enc = self._cipher.encrypt(subject, aad=_aad(draft_id, "subject"))
            row.updated_at = self._clock.now()
            await session.commit()
            return self._view(row)

    async def _transition(self, draft_id: str, status: str, external_id: str | None = None) -> DraftView:
        async with self._sf() as session:
            row = await session.get(MessageDraftRow, draft_id)
            if row is None:
                raise NotFound("That draft does not exist.", code="draft_not_found")
            if row.status != _OPEN and not (row.status == status):
                raise Conflict(f"The draft is already {row.status}.", code="draft_not_open")
            now = self._clock.now()
            row.status = status
            row.updated_at = now
            if status in ("sent", "handed_off"):
                row.sent_at = row.sent_at or now
            if external_id:
                row.external_id = external_id
            await session.commit()
            return self._view(row)

    async def mark_sent(self, draft_id: str, external_id: str | None = None) -> DraftView:
        return await self._transition(draft_id, "sent", external_id)

    async def mark_handed_off(self, draft_id: str) -> DraftView:
        return await self._transition(draft_id, "handed_off")

    async def discard(self, draft_id: str) -> DraftView:
        return await self._transition(draft_id, "discarded")

    async def set_external(self, draft_id: str, external_id: str) -> None:
        async with self._sf() as session:
            row = await session.get(MessageDraftRow, draft_id)
            if row is not None:
                row.external_id = external_id
                row.updated_at = self._clock.now()
                await session.commit()

    async def matches(
        self, draft_id: str, *, channel: str, address: str, text: str, subject: str | None = None
    ) -> DraftView | None:
        """The open draft when it carries exactly this channel, address, text (and subject); else None."""
        view = await self.find(draft_id)
        if view is None or view.status != _OPEN:
            return None
        ok = view.channel == channel and view.recipient_address == address and view.text == text
        if subject is not None:
            ok = ok and view.subject == subject
        return view if ok else None
