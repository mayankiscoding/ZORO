"""Document tables. Chunk text of documents above `personal` sensitivity is sealed at rest."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime
from app.db.types import EmbeddingType
from app.memory.models import EMBED_DIM


class DocumentRow(Base):
    __tablename__ = "documents"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    kind: Mapped[str] = mapped_column(String(8))  # pdf | txt | md | csv
    size_bytes: Mapped[int] = mapped_column(BigInteger)
    sha256: Mapped[str] = mapped_column(String(64), unique=True)
    object_key: Mapped[str] = mapped_column(String(300))
    sensitivity: Mapped[str] = mapped_column(String(16))
    page_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    chunk_count: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)


class DocumentChunkRow(Base):
    __tablename__ = "document_chunks"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    document_id: Mapped[str] = mapped_column(String(64), index=True)
    idx: Mapped[int] = mapped_column(Integer)
    page: Mapped[int | None] = mapped_column(Integer, nullable=True)
    text_plain: Mapped[str | None] = mapped_column(Text, nullable=True)
    text_enc: Mapped[str | None] = mapped_column(Text, nullable=True)
    sensitivity: Mapped[str] = mapped_column(String(16))
    embedding: Mapped[list[float] | None] = mapped_column(EmbeddingType(EMBED_DIM), nullable=True)
    embed_model: Mapped[str | None] = mapped_column(String(64), nullable=True)

    __table_args__ = (Index("ix_document_chunks_doc_idx", "document_id", "idx"),)
