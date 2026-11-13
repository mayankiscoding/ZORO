"""MemoryService (registered as service ``memory``): add with near-duplicate merge, hybrid search,
recall, review, correction, verification and deletion.

Rules enforced here, in code: text above `personal` sensitivity is sealed at rest; a disabled
category stores nothing and recalls nothing; a record the owner edited is never overwritten by a
later near-duplicate; a hard delete removes the row, and with it the vector; credentials are refused.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable, Iterable
from datetime import datetime, timedelta
from typing import TYPE_CHECKING, Any

from sqlalchemy import or_, select

from app.core.clock import Clock
from app.core.errors import BadRequest, Forbidden, NotFound
from app.core.ids import new_id
from app.core.types import DataClass, MemoryCategory, PrivacyMode, RiskLevel
from app.db.session import SessionFactory
from app.memory.access import allowed_classes
from app.memory.classify import (
    detect_sensitivity,
    max_sensitivity,
)
from app.memory.embedding import embed_texts
from app.memory.merge import find_duplicate, merge_into
from app.memory.models import MemoryRow
from app.memory.prefs import MemoryPrefs
from app.memory.proposals import propose_from_turn
from app.memory.retrieval import hybrid_search
from app.memory.types import (
    AddResult,
    MemoryHit,
    RecallItem,
    Status,
    clean_text,
    is_sealed,
)
from app.schemas.common import Page
from app.schemas.data import MemoryPatch, MemoryRecord, MemorySettings
from app.security.crypto import FieldCipher
from app.tools.state import DEFAULT_TTL_S

if TYPE_CHECKING:
    from app.tools.spec import ToolContext

log = logging.getLogger(__name__)

Purger = Callable[[], Awaitable[int]]
Exporter = Callable[[], Awaitable[list[dict[str, Any]]]]


class MemoryService:
    def __init__(
        self,
        session_factory: SessionFactory,
        cipher: FieldCipher,
        clock: Clock,
        *,
        prefs: MemoryPrefs,
        audit: Any | None = None,
        proofs: Any | None = None,
        gateway: Callable[[], Any | None] = lambda: None,
        privacy: Callable[[], Any | None] = lambda: None,
        conversation_state: Callable[[], Any | None] = lambda: None,
    ) -> None:
        self._sf = session_factory
        self._cipher = cipher
        self._clock = clock
        self.prefs = prefs
        self._audit = audit
        self._proofs = proofs
        self._gateway = gateway
        self._privacy = privacy
        self._conversation_state = conversation_state
        self._purgers: dict[MemoryCategory, list[Purger]] = {}
        self._exporters: dict[MemoryCategory, list[Exporter]] = {}

    # ------------------------------------------------------------ hooks for sibling packages

    def add_purger(self, category: MemoryCategory, purger: Purger) -> None:
        """Called by `delete_category` so another package (documents) can remove what it keeps under
        a category. Returns the number of items removed."""
        self._purgers.setdefault(category, []).append(purger)

    def add_exporter(self, category: MemoryCategory, exporter: Exporter) -> None:
        self._exporters.setdefault(category, []).append(exporter)

    @property
    def session_factory(self) -> SessionFactory:
        return self._sf

    def default_gateway(self) -> Any | None:
        return self._gateway()

    def purgers_for(self, category: MemoryCategory) -> list[Purger]:
        return list(self._purgers.get(category, []))

    def exporters_for(self, category: MemoryCategory) -> list[Exporter]:
        return list(self._exporters.get(category, []))

    # ------------------------------------------------------------ small helpers

    def now(self) -> datetime:
        return self._clock.now()

    async def current_mode(self) -> PrivacyMode:
        privacy = self._privacy()
        return PrivacyMode.STRICT_PRIVATE if privacy is None else await privacy.get_mode()

    async def allowed_for(self, mode: PrivacyMode) -> frozenset[DataClass]:
        return await allowed_classes(self._privacy(), mode)

    async def audit(
        self,
        action: str,
        *,
        actor: str = "system",
        detail: str = "",
        decision: str = "info",
        risk: RiskLevel | None = None,
        classes: Iterable[DataClass] = (),
    ) -> None:
        if self._audit is not None:
            await self._audit.append(
                actor=actor, action=action, decision=decision, risk=risk, data_classes=classes, detail=detail
            )

    def _aad(self, row_id: str) -> str:
        return f"memory|{row_id}"

    def text_of(self, row: MemoryRow) -> str:
        if row.text_enc is not None:
            return self._cipher.decrypt_str(row.text_enc, aad=self._aad(row.id))
        return row.text_plain or ""

    def set_text(self, row: MemoryRow, text: str) -> None:
        if is_sealed(DataClass(row.sensitivity)):
            row.text_enc = self._cipher.encrypt(text, aad=self._aad(row.id))
            row.text_plain = None
        else:
            row.text_plain = text
            row.text_enc = None

    def record_of(self, row: MemoryRow) -> MemoryRecord:
        return MemoryRecord(
            id=row.id,
            category=MemoryCategory(row.category),
            text=self.text_of(row),
            source=row.source,
            confidence=row.confidence,
            sensitivity=DataClass(row.sensitivity),
            status=row.status,
            user_editable=row.user_editable,
            created_at=row.created_at,
            last_verified_at=row.last_verified_at,
            expires_at=row.expires_at,
        )

    def provenance_of(self, row: MemoryRow) -> dict[str, Any]:
        return {
            "edited_by_owner": row.edited_by_owner,
            "edit_count": row.edit_count,
            "mentions": row.mentions,
        }

    def _expiry(
        self,
        category: MemoryCategory,
        created: datetime,
        retention_days: int | None,
        explicit: datetime | None,
    ) -> datetime | None:
        options: list[datetime] = []
        if retention_days:
            options.append(created + timedelta(days=retention_days))
        if category is MemoryCategory.CONVERSATION_STATE:
            options.append(created + timedelta(seconds=DEFAULT_TTL_S))
        if explicit is not None:
            options.append(explicit)
        return min(options) if options else None

    def live_filter(self, now: datetime) -> Any:
        return or_(MemoryRow.expires_at.is_(None), MemoryRow.expires_at > now)

    async def _embed_row(self, row: MemoryRow, text: str, gateway: Any | None, mode: PrivacyMode) -> None:
        embedded = await embed_texts(
            gateway if gateway is not None else self._gateway(),
            [text],
            frozenset({DataClass(row.sensitivity)}),
            mode,
        )
        row.embedding = embedded.vectors[0]
        row.embed_model = embedded.model

    # ------------------------------------------------------------ add

    async def add(
        self,
        *,
        category: MemoryCategory,
        text: str,
        sensitivity: DataClass = DataClass.PERSONAL,
        source: str = "user",
        confidence: float = 1.0,
        status: Status = "active",
        user_editable: bool = True,
        expires_at: datetime | None = None,
        gateway: Any | None = None,
        mode: PrivacyMode | None = None,
    ) -> AddResult:
        clean = clean_text(text)
        detected = detect_sensitivity(clean)
        if DataClass.SECRET in (sensitivity, detected):
            return AddResult("rejected_secret")
        sens = max_sensitivity(sensitivity, detected)
        setting = await self.prefs.get(category)
        if not setting.enabled:
            return AddResult("skipped_disabled")
        mode = mode or await self.current_mode()
        gw = gateway if gateway is not None else self._gateway()
        embedded = await embed_texts(gw, [clean], frozenset({sens}), mode)
        vector, model = embedded.vectors[0], embedded.model
        now = self.now()
        confidence = min(1.0, max(0.0, confidence))

        async with self._sf() as session:
            duplicate = await find_duplicate(self, session, category, clean, vector, model, now)
            if duplicate is not None:
                outcome = merge_into(self, duplicate, clean, sens, confidence, status, vector, model, now)
                await session.commit()
                return AddResult(outcome, self.record_of(duplicate))
            row = MemoryRow(
                id=new_id("mem"),
                category=category.value,
                source=source[:200],
                confidence=confidence,
                sensitivity=sens.value,
                status=status,
                user_editable=user_editable,
                edited_by_owner=False,
                edit_count=0,
                mentions=1,
                created_at=now,
                updated_at=now,
                expires_at=self._expiry(category, now, setting.retention_days, expires_at),
                embedding=vector,
                embed_model=model,
            )
            self.set_text(row, clean)
            session.add(row)
            await session.commit()
            return AddResult("created", self.record_of(row))

    # ------------------------------------------------------------ search and recall

    async def search(
        self,
        query: str,
        *,
        category: MemoryCategory | None = None,
        limit: int = 10,
        statuses: tuple[str, ...] = ("active",),
        allowed: frozenset[DataClass] | None = None,
        only_enabled: bool = True,
        min_score: float = 0.2,
        gateway: Any | None = None,
        mode: PrivacyMode | None = None,
    ) -> list[MemoryHit]:
        """Hybrid ranking: 0.75 x cosine similarity of embeddings + 0.25 x share of query words present."""
        return await hybrid_search(
            self, query, category=category, limit=limit, statuses=statuses, allowed=allowed,
            only_enabled=only_enabled, min_score=min_score, gateway=gateway, mode=mode,
        )  # fmt: skip

    async def propose_from_turn(
        self, user_text: str, assistant_text: str, ctx: ToolContext
    ) -> list[AddResult]:
        """Explicit requests are stored deterministically; implicit facts go through the gateway only
        when permitted (see `app.memory.proposals`)."""
        return await propose_from_turn(self, user_text, assistant_text, ctx)

    async def recall_hits(
        self, query: str, *, category: MemoryCategory | None = None, limit: int = 5, ctx: ToolContext
    ) -> list[MemoryHit]:
        """Relevant memories for an agent: enabled categories, active records only, data classes the
        privacy mode allows, never past expiry (so conversation state never outlives its TTL)."""
        allowed = await self.allowed_for(ctx.privacy_mode)
        return await self.search(
            query, category=category, limit=limit, allowed=allowed, gateway=ctx.gateway, mode=ctx.privacy_mode
        )

    async def recall(self, query: str, *, limit: int = 5, ctx: ToolContext) -> list[RecallItem]:
        """`recall_hits` shaped for the agent loop: text with category, sensitivity, confidence, source."""
        return [
            RecallItem(
                id=h.record.id,
                category=h.record.category,
                text=h.record.text,
                sensitivity=h.record.sensitivity,
                confidence=h.record.confidence,
                source=h.record.source,
                score=round(h.score, 4),
                last_verified_at=h.record.last_verified_at,
            )
            for h in await self.recall_hits(query, limit=limit, ctx=ctx)
        ]

    # ------------------------------------------------------------ list, get, review, correct

    async def get(self, memory_id: str) -> MemoryRecord:
        async with self._sf() as session:
            row = await session.get(MemoryRow, memory_id)
            if row is None:
                raise NotFound("No such memory.", code="memory_not_found")
            return self.record_of(row)

    async def list(
        self,
        *,
        category: MemoryCategory | None = None,
        status: str | None = None,
        cursor: str | None = None,
        limit: int = 50,
    ) -> Page[MemoryRecord]:
        offset = int(cursor) if cursor and cursor.isdigit() else 0
        stmt = select(MemoryRow).where(self.live_filter(self.now()))
        if category is not None:
            stmt = stmt.where(MemoryRow.category == category.value)
        if status is not None:
            stmt = stmt.where(MemoryRow.status == status)
        stmt = stmt.order_by(MemoryRow.created_at.desc(), MemoryRow.id.desc()).offset(offset).limit(limit + 1)
        async with self._sf() as session:
            rows = list((await session.execute(stmt)).scalars())
            items = [self.record_of(r) for r in rows[:limit]]
        return Page[MemoryRecord](items=items, next_cursor=str(offset + limit) if len(rows) > limit else None)

    async def patch(
        self, memory_id: str, patch: MemoryPatch, *, actor: str = "system", gateway: Any | None = None
    ) -> MemoryRecord:
        """Owner edits. A text correction keeps `source`, `created_at` and the record id (provenance),
        marks the record as edited by the owner and verifies it."""
        now = self.now()
        async with self._sf() as session:
            row = await session.get(MemoryRow, memory_id)
            if row is None:
                raise NotFound("No such memory.", code="memory_not_found")
            if patch.text is not None:
                if not row.user_editable:
                    raise Forbidden(
                        "This memory is managed by ZORO and cannot be edited.", code="memory_not_editable"
                    )
                clean = clean_text(patch.text)
                detected = detect_sensitivity(clean)
                if detected is DataClass.SECRET:
                    raise BadRequest(
                        "Passwords, PINs and OTPs are never stored in memory.", code="memory_secret_refused"
                    )
                row.sensitivity = max_sensitivity(DataClass(row.sensitivity), detected).value
                self.set_text(row, clean)
                await self._embed_row(row, clean, gateway, await self.current_mode())
                row.edited_by_owner = True
                row.edit_count += 1
                row.confidence = 1.0
                row.last_verified_at = now
            if patch.status is not None:
                if patch.status == "active" and row.status == "pending_review":
                    row.last_verified_at = now  # approving a pending memory verifies it
                row.status = patch.status
            if patch.verified:
                row.last_verified_at = now
            row.updated_at = now
            await session.commit()
            record = self.record_of(row)
        await self.audit(
            "memory.update",
            actor=actor,
            detail=f"id={memory_id} fields={sorted(patch.model_dump(exclude_none=True))}",
        )
        return record

    async def delete(self, memory_id: str, *, actor: str = "system") -> bool:
        """Hard delete: the row and its embedding are gone."""
        async with self._sf() as session:
            row = await session.get(MemoryRow, memory_id)
            if row is None:
                return False
            category, sens = row.category, DataClass(row.sensitivity)
            await session.delete(row)
            await session.commit()
        await self.audit(
            "memory.delete", actor=actor, detail=f"id={memory_id} category={category}", classes=[sens]
        )
        return True

    # ------------------------------------------------------------ settings

    async def update_settings(self, new: MemorySettings, *, actor: str = "system") -> MemorySettings:
        changed = await self.prefs.update(new)
        if changed:
            async with self._sf() as session:
                for category, days in changed.items():
                    if days is None:
                        continue
                    rows = (
                        await session.execute(
                            select(MemoryRow).where(
                                MemoryRow.category == category.value, MemoryRow.status != "archived"
                            )
                        )
                    ).scalars()
                    for row in rows:
                        limit = row.created_at + timedelta(days=days)
                        row.expires_at = limit if row.expires_at is None else min(row.expires_at, limit)
                await session.commit()
        await self.audit(
            "memory.settings", actor=actor, detail=f"retention_changed={sorted(c.value for c in changed)}"
        )
        return await self.prefs.settings()
