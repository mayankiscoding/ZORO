"""Cosine vector search that works on PostgreSQL (pgvector `<=>`) and SQLite (in-process fallback)."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

import numpy as np
from sqlalchemy import ColumnElement, Float, Select, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import InstrumentedAttribute


def cosine_similarity(a: Sequence[float], b: Sequence[float]) -> float:
    """Cosine similarity in [-1, 1]; 0.0 when either vector has no length."""
    va = np.asarray(a, dtype=np.float64)
    vb = np.asarray(b, dtype=np.float64)
    if va.shape != vb.shape:
        raise ValueError("vectors have different dimensions")
    denom = float(np.linalg.norm(va) * np.linalg.norm(vb))
    if denom == 0.0:
        return 0.0
    return float(np.dot(va, vb) / denom)


def pgvector_statement[T](
    model: type[T],
    column: InstrumentedAttribute[Any],
    vector: Sequence[float],
    *,
    limit: int,
    where: Sequence[ColumnElement[bool]] = (),
) -> Select[T, float]:
    """`SELECT model, 1 - (column <=> :vector) AS score ... ORDER BY column <=> :vector LIMIT n`."""
    distance = column.op("<=>", return_type=Float())(list(vector))
    return (
        select(model, (1 - distance).label("score"))
        .where(column.is_not(None), *where)
        .order_by(distance)
        .limit(limit)
    )


async def vector_search[T](
    session: AsyncSession,
    model: type[T],
    column: InstrumentedAttribute[Any],
    query: Sequence[float],
    *,
    limit: int = 10,
    where: Sequence[ColumnElement[bool]] = (),
    min_score: float | None = None,
) -> list[tuple[T, float]]:
    """Nearest rows of `model` by cosine similarity of `column` (an `EmbeddingType`) to `query`.

    Returns `(row, score)` best first, `score` being cosine similarity (1.0 = same direction).
    Rows with a NULL embedding are skipped. `where` adds ordinary filters (owner, category, …).
    PostgreSQL ranks inside the database with pgvector; SQLite loads the filtered candidates and
    ranks them in process, which is fine for a personal-scale store.
    """
    if limit <= 0:
        return []
    vector = [float(x) for x in query]
    dialect = session.get_bind().dialect.name

    if dialect == "postgresql":
        rows = (
            await session.execute(pgvector_statement(model, column, vector, limit=limit, where=where))
        ).all()
        scored = [(row[0], float(row[1])) for row in rows]
    else:
        stmt_all = select(model).where(column.is_not(None), *where)
        candidates = (await session.execute(stmt_all)).scalars().all()
        scored = []
        for candidate in candidates:
            embedding = getattr(candidate, column.key)
            if embedding is None or len(embedding) != len(vector):
                continue
            scored.append((candidate, cosine_similarity(embedding, vector)))
        scored.sort(key=lambda pair: pair[1], reverse=True)
        scored = scored[:limit]

    if min_score is not None:
        scored = [pair for pair in scored if pair[1] >= min_score]
    return scored
