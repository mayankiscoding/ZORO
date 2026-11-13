"""Vision contracts. `PhotoQuery` is normative (docs/architecture/device-contract.md): the backend
parses the owner's words into it and the device searches its own index with it. Only text and photo
identifiers cross this API; there is no field anywhere that carries image bytes."""

from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.tools.followup import FollowUp

Media = Literal["photo", "screenshot", "any"]
MAX_TEXT = 500
DEFAULT_LIMIT = 30
MAX_LIMIT = 200
ASSET_ID = r"^[A-Za-z0-9/_.:+=@-]{1,200}$"  # PhotoKit local identifiers, never a path or a URL


class VModel(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)


class PhotoQuery(VModel):
    text: Annotated[str, Field(max_length=MAX_TEXT)] = ""
    date_from: date | None = None
    date_to: date | None = None
    colors: list[str] = Field(default_factory=list, max_length=10)
    labels: list[str] = Field(default_factory=list, max_length=20)
    contains_text: Annotated[str, Field(max_length=200)] | None = None
    media: Media = "any"
    limit: int = Field(default=DEFAULT_LIMIT, ge=1, le=MAX_LIMIT)

    @property
    def is_filtered(self) -> bool:
        return bool(self.date_from or self.colors or self.labels or self.contains_text or self.media != "any")


class ParseIn(VModel):
    text: Annotated[str, Field(min_length=1, max_length=MAX_TEXT)]
    timezone: Annotated[str, Field(max_length=64)] = "Asia/Kolkata"
    refine: bool = False


class ParsedQuery(VModel):
    query: PhotoQuery
    assumptions: list[str] = Field(default_factory=list)
    matched: dict[str, Any] = Field(default_factory=dict)  # what each part of the query came from
    text_source: Literal["original", "model"] = "original"
    # parse (done) -> device.photos.search -> vision.show_photo_results (`app.tools.followup`)
    follow_ups: list[FollowUp] = Field(default_factory=list)


class ParseToolIn(VModel):
    text: Annotated[str, Field(min_length=1, max_length=MAX_TEXT)]
    refine: bool = Field(
        default=True,
        description="Let the model rephrase the search text only (dates and filters stay as parsed).",
    )


class PhotoHitIn(VModel):
    asset_id: Annotated[str, Field(pattern=ASSET_ID)]
    captured_at: datetime | None = None
    score: float = Field(default=0.0, allow_inf_nan=False)
    labels: list[Annotated[str, Field(max_length=60)]] = Field(default_factory=list, max_length=20)
    matched: list[str] = Field(default_factory=list, max_length=20)  # accepted, never passed on


class ShowResultsIn(VModel):
    query: PhotoQuery
    hits: list[PhotoHitIn] = Field(default_factory=list, max_length=MAX_LIMIT)
    indexed_count: int = Field(default=0, ge=0)
    limited_library: bool = False


class PhotoHitOut(VModel):
    asset_id: str
    captured_at: datetime | None = None
    score: float = 0.0
    labels: list[str] = Field(default_factory=list)


class ShowResultsOut(VModel):
    query: PhotoQuery
    hits: list[PhotoHitOut]
    asset_ids: list[str]
    indexed_count: int = 0
    limited_library: bool = False
