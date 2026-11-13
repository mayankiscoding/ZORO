"""Portable column types: JSON (JSONB on PostgreSQL) and embeddings (pgvector on PostgreSQL)."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

from sqlalchemy import JSON
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.engine import Dialect
from sqlalchemy.types import TypeDecorator, TypeEngine


class JSONType(TypeDecorator[Any]):
    """JSON document column: `JSONB` on PostgreSQL, `JSON` elsewhere.

    Values are plain JSON-native Python objects. In-place mutation is not tracked: assign a new
    object to persist a change.
    """

    impl = JSON
    cache_ok = True

    def load_dialect_impl(self, dialect: Dialect) -> TypeEngine[Any]:
        if dialect.name == "postgresql":
            return dialect.type_descriptor(JSONB())
        return dialect.type_descriptor(JSON())


class EmbeddingType(TypeDecorator[list[float]]):
    """Fixed-dimension embedding: pgvector `VECTOR(dim)` on PostgreSQL, a JSON array on SQLite.

    Python side is always `list[float]`. Search with `app.db.vector.vector_search`.
    """

    impl = JSON
    cache_ok = True

    def __init__(self, dim: int) -> None:
        if dim <= 0:
            raise ValueError("embedding dimension must be positive")
        super().__init__()
        self.dim = dim

    def __repr__(self) -> str:  # rendered into Alembic migrations, so it must round-trip
        return f"EmbeddingType({self.dim})"

    def load_dialect_impl(self, dialect: Dialect) -> TypeEngine[Any]:
        if dialect.name == "postgresql":
            from pgvector.sqlalchemy import Vector

            return dialect.type_descriptor(Vector(self.dim))
        return dialect.type_descriptor(JSON())

    def process_bind_param(self, value: Sequence[float] | None, dialect: Dialect) -> Any:
        if value is None:
            return None
        vector = [float(x) for x in value]
        if len(vector) != self.dim:
            raise ValueError(f"embedding has {len(vector)} dimensions, column expects {self.dim}")
        return vector

    def process_result_value(self, value: Any, dialect: Dialect) -> list[float] | None:
        if value is None:
            return None
        return [float(x) for x in value]
