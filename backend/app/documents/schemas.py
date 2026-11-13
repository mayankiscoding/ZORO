"""Documents API contract."""

from __future__ import annotations

from typing import Literal

from pydantic import AwareDatetime

from app.core.types import DataClass
from app.schemas.common import ZModel

DocKind = Literal["pdf", "txt", "md", "csv"]


class DocumentInfo(ZModel):
    id: str
    title: str
    kind: DocKind
    size_bytes: int
    sha256: str
    sensitivity: DataClass
    page_count: int | None = None
    chunk_count: int
    created_at: AwareDatetime


class DocumentHit(ZModel):
    document_id: str
    title: str
    chunk_index: int
    page: int | None = None
    text: str
    score: float
    sensitivity: DataClass
    source: str  # "document:{id}" for provenance


class StoredObjectInfo(ZModel):
    key: str
    size: int
    content_type: str | None = None
    document_id: str | None = None
    title: str | None = None
