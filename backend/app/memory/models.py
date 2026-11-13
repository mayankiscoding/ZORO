"""Memory tables. Text of records above `personal` sensitivity is sealed (`text_enc`); the plain
column is then NULL, so the raw table never holds it."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, Float, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime
from app.db.types import EmbeddingType

EMBED_DIM = 256  # the local `local-hash-v1` embedder; other models of another size use the local one


class MemoryRow(Base):
    __tablename__ = "memory_records"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    category: Mapped[str] = mapped_column(String(32), index=True)
    text_plain: Mapped[str | None] = mapped_column(Text, nullable=True)
    text_enc: Mapped[str | None] = mapped_column(Text, nullable=True)
    source: Mapped[str] = mapped_column(String(200))
    confidence: Mapped[float] = mapped_column(Float, default=1.0)
    sensitivity: Mapped[str] = mapped_column(String(16))
    status: Mapped[str] = mapped_column(String(16), default="active")
    user_editable: Mapped[bool] = mapped_column(Boolean, default=True)
    edited_by_owner: Mapped[bool] = mapped_column(Boolean, default=False)
    edit_count: Mapped[int] = mapped_column(Integer, default=0)
    mentions: Mapped[int] = mapped_column(Integer, default=1)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)
    last_verified_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    expires_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    embedding: Mapped[list[float] | None] = mapped_column(EmbeddingType(EMBED_DIM), nullable=True)
    embed_model: Mapped[str | None] = mapped_column(String(64), nullable=True)

    __table_args__ = (Index("ix_memory_records_status_created", "status", "created_at"),)


class MemoryCategorySettingRow(Base):
    __tablename__ = "memory_category_settings"

    category: Mapped[str] = mapped_column(String(32), primary_key=True)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    retention_days: Mapped[int | None] = mapped_column(Integer, nullable=True)


class MemoryMetaRow(Base):
    """Small key/value store for memory-wide settings (conversation retention)."""

    __tablename__ = "memory_meta"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(String(200))
