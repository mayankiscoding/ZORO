"""Hybrid retrieval over memory records: embedding cosine similarity plus keyword overlap."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from sqlalchemy import select

from app.core.types import DataClass, MemoryCategory, PrivacyMode
from app.db.vector import vector_search
from app.memory.access import ALL_BUT_SECRET
from app.memory.classify import classify, keyword_score, tokens
from app.memory.embedding import query_vectors
from app.memory.models import MemoryRow
from app.memory.types import CANDIDATE_SCAN, MemoryHit

if TYPE_CHECKING:
    from app.memory.service import MemoryService


async def hybrid_search(
    service: MemoryService,
    query: str,
    *,
    category: MemoryCategory | None,
    limit: int,
    statuses: tuple[str, ...],
    allowed: frozenset[DataClass] | None,
    only_enabled: bool,
    min_score: float,
    gateway: Any | None,
    mode: PrivacyMode | None,
) -> list[MemoryHit]:
    query = query.strip()
    if not query or limit <= 0:
        return []
    cats = list(MemoryCategory) if category is None else [category]
    if only_enabled:
        enabled = set(await service.prefs.enabled_categories())
        cats = [c for c in cats if c in enabled]
    if not cats:
        return []
    classes = allowed if allowed is not None else ALL_BUT_SECRET
    mode = mode or await service.current_mode()
    q_tokens = tokens(query)
    vectors = await query_vectors(
        gateway if gateway is not None else service.default_gateway(),
        query,
        frozenset({classify(query).sensitivity}) - {DataClass.SECRET} or frozenset({DataClass.PERSONAL}),
        mode,
    )
    where = [
        MemoryRow.category.in_([c.value for c in cats]),
        MemoryRow.status.in_(statuses),
        MemoryRow.sensitivity.in_([c.value for c in classes]),
        service.live_filter(service.now()),
    ]
    found: dict[str, tuple[MemoryRow, float, float]] = {}
    async with service.session_factory() as session:
        for model, vector in vectors.items():
            for row, cosine in await vector_search(
                session, MemoryRow, MemoryRow.embedding, vector, limit=limit * 4,
                where=[*where, MemoryRow.embed_model == model],
            ):  # fmt: skip
                found[row.id] = (row, max(cosine, found.get(row.id, (row, 0.0, 0.0))[1]), 0.0)
        for row in (await session.execute(select(MemoryRow).where(*where).limit(CANDIDATE_SCAN))).scalars():
            kw = keyword_score(q_tokens, service.text_of(row))
            if kw > 0 or row.id in found:
                found[row.id] = (row, found.get(row.id, (row, 0.0, 0.0))[1], kw)
        hits = [MemoryHit(service.record_of(row), 0.75 * cos + 0.25 * kw) for row, cos, kw in found.values()]
    hits = [h for h in hits if h.score >= min_score]
    hits.sort(key=lambda h: (-h.score, h.record.created_at))
    return hits[:limit]
