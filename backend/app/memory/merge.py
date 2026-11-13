"""Near-duplicate detection and merge for `MemoryService.add`."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING, Literal

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.types import DataClass, MemoryCategory
from app.db.vector import vector_search
from app.memory.classify import max_sensitivity, normalise
from app.memory.models import MemoryRow
from app.memory.types import NEAR_DUPLICATE, Status

if TYPE_CHECKING:
    from app.memory.service import MemoryService


async def find_duplicate(
    service: MemoryService,
    session: AsyncSession,
    category: MemoryCategory,
    text: str,
    vector: list[float],
    model: str,
    now: datetime,
) -> MemoryRow | None:
    """The live record of this category that says (nearly) the same thing, embedded by the same model."""
    hits = await vector_search(
        session,
        MemoryRow,
        MemoryRow.embedding,
        vector,
        limit=3,
        where=[
            MemoryRow.category == category.value,
            MemoryRow.status != "archived",
            MemoryRow.embed_model == model,
            service.live_filter(now),
        ],
        min_score=NEAR_DUPLICATE,
    )
    wanted = normalise(text)
    for row, _score in hits:
        if normalise(service.text_of(row)) == wanted:
            return row
    return hits[0][0] if hits else None


def merge_into(
    service: MemoryService,
    row: MemoryRow,
    text: str,
    sens: DataClass,
    confidence: float,
    status: Status,
    vector: list[float],
    model: str,
    now: datetime,
) -> Literal["merged", "kept_existing"]:
    """Fold a new sighting into an existing record. A record the owner edited (or that is locked) is
    never overwritten: the existing one is kept as it is."""
    if row.edited_by_owner or not row.user_editable:
        return "kept_existing"
    row.mentions += 1
    row.updated_at = now
    row.confidence = max(row.confidence, confidence)
    if row.status == "pending_review" and status == "active":
        row.status = "active"
    raised = max_sensitivity(DataClass(row.sensitivity), sens)
    replace = normalise(text) != normalise(service.text_of(row)) and confidence >= row.confidence - 1e-9
    current = text if replace else service.text_of(row)
    if raised.value != row.sensitivity:
        row.sensitivity = raised.value
        service.set_text(row, current)
    elif replace:
        service.set_text(row, current)
    if replace:
        row.embedding, row.embed_model = vector, model
    return "merged"
