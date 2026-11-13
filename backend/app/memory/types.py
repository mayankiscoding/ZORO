"""Value types and small helpers of the memory service."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Literal

from pydantic import BaseModel

from app.core.errors import BadRequest
from app.core.types import DataClass, MemoryCategory
from app.schemas.data import MemoryRecord

Status = Literal["active", "pending_review", "archived"]
NEAR_DUPLICATE = 0.9
MAX_TEXT = 2000
CANDIDATE_SCAN = 2000


@dataclass(frozen=True)
class AddResult:
    outcome: Literal["created", "merged", "kept_existing", "skipped_disabled", "rejected_secret"]
    record: MemoryRecord | None = None

    @property
    def stored(self) -> bool:
        return self.outcome in ("created", "merged", "kept_existing")


@dataclass(frozen=True)
class MemoryHit:
    record: MemoryRecord
    score: float


class RecallItem(BaseModel):
    """What recall hands to an agent: the text with its provenance and data class."""

    id: str
    category: MemoryCategory
    text: str
    sensitivity: DataClass
    confidence: float
    source: str
    score: float
    last_verified_at: datetime | None = None


def clean_text(text: str) -> str:
    clean = " ".join(text.split())
    if not clean:
        raise BadRequest("A memory needs some text.", code="memory_text_empty")
    if len(clean) > MAX_TEXT:
        raise BadRequest(f"A memory can be at most {MAX_TEXT} characters.", code="memory_text_too_long")
    return clean


def is_sealed(sensitivity: DataClass) -> bool:
    return sensitivity.rank > DataClass.PERSONAL.rank
