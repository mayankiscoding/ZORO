"""VisionService: parse (deterministic), optionally refine the text, build the search plan."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from app.core.types import PrivacyMode
from app.tools.followup import FollowUp
from app.vision.parser import parse_photo_query
from app.vision.refine import refine_query_text
from app.vision.schemas import ParsedQuery, PhotoQuery

SEARCH_TOOL = "device.photos.search"
SHOW_TOOL = "vision.show_photo_results"


def build_plan(query: PhotoQuery) -> list[FollowUp]:
    """What follows the parse: the device searches its own index, then the results are shown."""
    q = query.model_dump(mode="json")
    return [
        FollowUp(tool=SEARCH_TOOL, args={"query": q}),
        FollowUp(
            tool=SHOW_TOOL,
            args={"query": q},
            args_from_previous={
                "hits": "hits",
                "indexed_count": "indexed_count",
                "limited_library": "limited_library",
            },
        ),
    ]


class VisionService:
    def __init__(self, gateway_provider: Any = None) -> None:
        self._gateway = (
            gateway_provider  # () -> gateway | None, read lazily (the gateway plugin may load later)
        )

    def gateway(self) -> Any | None:
        return self._gateway() if callable(self._gateway) else None

    async def parse(
        self,
        text: str,
        now: datetime,
        tz: str = "Asia/Kolkata",
        *,
        refine: bool = False,
        privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE,
        gateway: Any | None = None,
    ) -> ParsedQuery:
        parsed = parse_photo_query(text, now, tz)
        query, source = parsed.query, "original"
        if refine:
            better = await refine_query_text(gateway or self.gateway(), query.text, privacy_mode=privacy_mode)
            if better is not None:
                query, source = query.model_copy(update={"text": better}), "model"
        return ParsedQuery(
            query=query,
            assumptions=list(parsed.assumptions),
            matched=parsed.matched,
            text_source=source,
            follow_ups=build_plan(query),
        )
