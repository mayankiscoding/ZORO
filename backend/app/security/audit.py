"""Append-only, hash-chained audit log.

``hash = sha256(prev_hash + canonical record)``. Each append runs in its own transaction, so an
audit entry survives the rollback of whatever it describes. `detail` is a short summary: callers
pass argument names and outcomes, never raw payloads; it is pattern-redacted and truncated here
as a second line of defence.
"""

from __future__ import annotations

import asyncio
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Literal, cast

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.core.clock import Clock, SystemClock
from app.core.ids import canonical_json, new_id, sha256_hex
from app.core.logging import redact_text
from app.core.types import DataClass, RiskLevel
from app.db.session import SessionFactory
from app.schemas.common import Page
from app.schemas.security import AuditRecord
from app.security.models import AuditRow

GENESIS_HASH = "0" * 64
_MAX_DETAIL = 500
_APPEND_ATTEMPTS = 5

AuditDecision = Literal["allowed", "approved", "denied", "blocked", "failed", "info"]


@dataclass(frozen=True)
class ChainStatus:
    ok: bool
    records: int
    broken_at: str | None = None  # id of the first record that fails
    reason: str | None = None  # "hash_mismatch" | "broken_link"


def _canonical_ts(ts: datetime) -> str:
    return ts.astimezone(UTC).isoformat(timespec="microseconds")


def record_hash(prev_hash: str, row: AuditRow) -> str:
    record = {
        "id": row.id,
        "ts": _canonical_ts(row.ts),
        "actor": row.actor,
        "action": row.action,
        "tool": row.tool,
        "risk": row.risk,
        "decision": row.decision,
        "data_classes": sorted(row.data_classes or []),
        "detail": row.detail,
    }
    return sha256_hex(prev_hash + canonical_json(record))


def _to_record(row: AuditRow) -> AuditRecord:
    return AuditRecord(
        id=row.id,
        ts=row.ts,
        actor=row.actor,
        action=row.action,
        tool=row.tool,
        risk=RiskLevel(row.risk) if row.risk else None,
        decision=cast(AuditDecision, row.decision),
        data_classes=[DataClass(value) for value in row.data_classes or []],
        detail=row.detail,
        prev_hash=row.prev_hash,
        hash=row.hash,
    )


class AuditLog:
    def __init__(self, session_factory: SessionFactory, clock: Clock | None = None) -> None:
        self._sf = session_factory
        self._clock = clock or SystemClock()
        self._lock = asyncio.Lock()

    async def append(
        self,
        *,
        actor: str,
        action: str,
        decision: AuditDecision = "info",
        tool: str | None = None,
        risk: RiskLevel | None = None,
        data_classes: Iterable[DataClass] = (),
        detail: str = "",
    ) -> AuditRecord:
        """Append one record and return it. Serialised in-process; a unique `prev_hash` stops a
        second process from forking the chain (the loser retries on the new head)."""
        classes = sorted({DataClass(value).value for value in data_classes})
        clean_detail = redact_text(detail)[:_MAX_DETAIL]
        last_error: Exception | None = None
        async with self._lock:
            for _ in range(_APPEND_ATTEMPTS):
                async with self._sf() as session:
                    head = (
                        await session.execute(select(AuditRow.hash).order_by(AuditRow.seq.desc()).limit(1))
                    ).scalar_one_or_none()
                    row = AuditRow(
                        id=new_id("aud"),
                        ts=self._clock.now(),
                        actor=actor[:100],
                        action=action[:100],
                        tool=tool,
                        risk=risk.value if risk is not None else None,
                        decision=decision,
                        data_classes=classes,
                        detail=clean_detail,
                        prev_hash=head or GENESIS_HASH,
                        hash="",
                    )
                    row.hash = record_hash(row.prev_hash, row)
                    session.add(row)
                    try:
                        await session.commit()
                    except IntegrityError as exc:
                        await session.rollback()
                        last_error = exc
                        continue
                    return _to_record(row)
        raise RuntimeError("audit append failed after retries") from last_error

    async def list(self, *, cursor: str | None = None, limit: int = 50) -> Page[AuditRecord]:
        """Newest first. `cursor` is the opaque `next_cursor` of the previous page."""
        limit = max(1, min(limit, 200))
        stmt = select(AuditRow).order_by(AuditRow.seq.desc()).limit(limit + 1)
        if cursor:
            try:
                before = int(cursor)
            except ValueError:
                before = 0
            stmt = stmt.where(AuditRow.seq < before)
        async with self._sf() as session:
            rows = list((await session.execute(stmt)).scalars().all())
        more = len(rows) > limit
        rows = rows[:limit]
        return Page[AuditRecord](
            items=[_to_record(row) for row in rows],
            next_cursor=str(rows[-1].seq) if more and rows else None,
        )

    async def verify_chain(self, *, batch: int = 500) -> ChainStatus:
        """Walk the whole chain oldest first; report the first record whose link or hash is wrong.

        Detects edits, insertions and removals anywhere except truncation of the newest records
        (there is no external anchor for the head).
        """
        prev = GENESIS_HASH
        checked = 0
        last_seq = 0
        while True:
            async with self._sf() as session:
                rows = (
                    (
                        await session.execute(
                            select(AuditRow)
                            .where(AuditRow.seq > last_seq)
                            .order_by(AuditRow.seq)
                            .limit(batch)
                        )
                    )
                    .scalars()
                    .all()
                )
            if not rows:
                return ChainStatus(ok=True, records=checked)
            for row in rows:
                if row.prev_hash != prev:
                    return ChainStatus(False, checked, broken_at=row.id, reason="broken_link")
                if record_hash(row.prev_hash, row) != row.hash:
                    return ChainStatus(False, checked, broken_at=row.id, reason="hash_mismatch")
                prev = row.hash
                last_seq = row.seq
                checked += 1
