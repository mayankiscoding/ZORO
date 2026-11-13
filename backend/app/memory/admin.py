"""Signed, audited memory operations (export, delete a whole category) and the retention sweeper."""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import Callable
from typing import Any

from sqlalchemy import delete, select

from app.core.errors import ZoroError
from app.core.types import DataClass, MemoryCategory, RiskLevel
from app.memory.models import MemoryRow
from app.memory.service import MemoryService
from app.schemas.common import SignedProof

log = logging.getLogger(__name__)

EXPORT_FORMAT = "zoro-memory-export-v1"
SWEEP_BATCH = 500


class MemoryAdmin:
    def __init__(
        self,
        service: MemoryService,
        *,
        proofs: Any,
        conversation_state: Callable[[], Any | None] = lambda: None,
    ) -> None:
        self._service = service
        self._proofs = proofs
        self._conversation_state = conversation_state

    async def _verify(
        self, proof: SignedProof, *, action: str, subject: str, device_id: str, audit_action: str
    ) -> None:
        try:
            await self._proofs.verify(proof, action=action, subject=subject, expected_device_id=device_id)
        except ZoroError as exc:
            await self._service.audit(
                audit_action,
                actor=device_id,
                decision="denied",
                risk=RiskLevel.CRITICAL,
                detail=f"subject={subject} reason={exc.error_code}",
            )
            raise

    async def export(
        self, category: MemoryCategory | None, proof: SignedProof, *, device_id: str
    ) -> dict[str, Any]:
        """Everything in one category (or all of memory) as a JSON document. CRITICAL and audited;
        needs a fresh, unused proof of the approval key for ``export_memory|{category or all}``."""
        subject = category.value if category is not None else "all"
        await self._verify(
            proof, action="export_memory", subject=subject, device_id=device_id, audit_action="memory.export"
        )
        service = self._service
        stmt = (
            select(MemoryRow)
            .where(service.live_filter(service.now()))
            .order_by(MemoryRow.created_at, MemoryRow.id)
        )
        if category is not None:
            stmt = stmt.where(MemoryRow.category == category.value)
        async with service.session_factory() as session:
            rows = list((await session.execute(stmt)).scalars())
            records = [
                {**service.record_of(r).model_dump(mode="json"), **service.provenance_of(r)} for r in rows
            ]
            classes = {DataClass(r.sensitivity) for r in rows}
        extras: dict[str, list[dict[str, Any]]] = {}
        for cat in [category] if category is not None else list(MemoryCategory):
            for exporter in service.exporters_for(cat):
                extras.setdefault(cat.value, []).extend(await exporter())
        await service.audit(
            "memory.export",
            actor=device_id,
            decision="approved",
            risk=RiskLevel.CRITICAL,
            classes=classes,
            detail=f"subject={subject} count={len(records)}",
        )
        return {
            "format": EXPORT_FORMAT,
            "exported_at": service.now().isoformat(),
            "category": category.value if category else None,
            "count": len(records),
            "records": records,
            "extras": extras,
        }

    async def delete_category(self, category: MemoryCategory, proof: SignedProof, *, device_id: str) -> int:
        """Remove every record of a category (and what other packages keep under it)."""
        await self._verify(
            proof,
            action="delete_memory_category",
            subject=category.value,
            device_id=device_id,
            audit_action="memory.delete_category",
        )
        service = self._service
        async with service.session_factory() as session:
            ids = list(
                (
                    await session.execute(select(MemoryRow.id).where(MemoryRow.category == category.value))
                ).scalars()
            )
            if ids:
                await session.execute(delete(MemoryRow).where(MemoryRow.category == category.value))
            await session.commit()
        removed = len(ids)
        for purger in service.purgers_for(category):
            removed += await purger()
        await service.audit(
            "memory.delete_category",
            actor=device_id,
            decision="approved",
            risk=RiskLevel.CRITICAL,
            detail=f"category={category.value} removed={removed}",
        )
        return removed

    async def sweep(self, limit: int = SWEEP_BATCH) -> int:
        """Retention: delete records past `expires_at` (row and vector), at most `limit` per pass, and
        drop expired temporary conversation state."""
        service = self._service
        async with service.session_factory() as session:
            ids = list(
                (
                    await session.execute(
                        select(MemoryRow.id)
                        .where(MemoryRow.expires_at.is_not(None), MemoryRow.expires_at <= service.now())
                        .limit(limit)
                    )
                ).scalars()
            )
            if ids:
                await session.execute(delete(MemoryRow).where(MemoryRow.id.in_(ids)))
                await session.commit()
        state = self._conversation_state()
        if state is not None:
            await state.purge_expired()
        if ids:
            await service.audit("memory.retention_sweep", detail=f"removed={len(ids)}")
        return len(ids)


class RetentionSweeper:
    """Background task started at app startup, cancelled on shutdown. Each pass is bounded."""

    def __init__(self, admin: MemoryAdmin, *, interval_s: float = 900.0) -> None:
        self._admin = admin
        self._interval = interval_s
        self._task: asyncio.Task[None] | None = None

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    async def start(self) -> None:
        if not self.running:
            self._task = asyncio.create_task(self._run(), name="memory-retention-sweeper")

    async def stop(self) -> None:
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    async def _run(self) -> None:
        while True:
            try:
                await self._admin.sweep()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.error("memory sweep failed", extra={"error_type": type(exc).__name__})
            await asyncio.sleep(self._interval)
