"""Database kernel: declarative base, engine and session factory, portable types, vector search."""

from app.db.base import Base, TimestampMixin, UTCDateTime, new_id, utcnow
from app.db.discovery import import_models, model_packages
from app.db.session import (
    Database,
    SessionFactory,
    create_engine,
    create_session_factory,
    init_db,
)
from app.db.types import EmbeddingType, JSONType
from app.db.vector import cosine_similarity, vector_search

__all__ = [
    "Base",
    "Database",
    "EmbeddingType",
    "JSONType",
    "SessionFactory",
    "TimestampMixin",
    "UTCDateTime",
    "cosine_similarity",
    "create_engine",
    "create_session_factory",
    "import_models",
    "init_db",
    "model_packages",
    "new_id",
    "utcnow",
    "vector_search",
]
