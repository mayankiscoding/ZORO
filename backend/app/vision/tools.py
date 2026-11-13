"""Vision tools (both LOW, backend): parse the words into a `PhotoQuery`, then present what the
device found. The search itself is the device tool `device.photos.search`; images never reach here."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel

from app.core.types import AgentId, DataClass, RiskLevel
from app.tools.spec import ToolContext, ToolSpec
from app.vision import summaries as s
from app.vision.schemas import (
    ParsedQuery,
    ParseToolIn,
    PhotoHitOut,
    ShowResultsIn,
    ShowResultsOut,
)
from app.vision.service import VisionService

PERMISSION = "vision.search"
GROUP = "ios-photos-mcp"
AGENTS = frozenset({AgentId.VISION, AgentId.PERSONAL_ASSISTANT, AgentId.VOICE, AgentId.DEVICE_CONTROL})
WORKING_SET = "photos"


def build_tools(svc: VisionService) -> list[ToolSpec]:
    async def parse(ctx: ToolContext, a: ParseToolIn) -> ParsedQuery:
        return await svc.parse(
            a.text,
            ctx.now(),
            ctx.timezone,
            refine=a.refine,
            privacy_mode=ctx.privacy_mode,
            gateway=ctx.gateway,
        )

    async def show(ctx: ToolContext, a: ShowResultsIn) -> ShowResultsOut:
        hits = [
            PhotoHitOut(asset_id=h.asset_id, captured_at=h.captured_at, score=h.score, labels=h.labels)
            for h in a.hits
        ]  # `matched` (text recognised in screenshots) is dropped: only identifiers and labels go on
        await ctx.set_working_set(
            WORKING_SET,
            [
                {
                    "asset_id": h.asset_id,
                    "captured_at": h.captured_at.isoformat() if h.captured_at else None,
                    "labels": h.labels,
                }
                for h in hits
            ],
        )
        return ShowResultsOut(
            query=a.query,
            hits=hits,
            asset_ids=[h.asset_id for h in hits],
            indexed_count=a.indexed_count,
            limited_library=a.limited_library,
        )

    def spec(
        name: str,
        description: str,
        inp: type[BaseModel],
        out: type[BaseModel],
        handler: Any,
        summarizer: Any,
        card: Any,
    ) -> ToolSpec:
        return ToolSpec(
            name=name,
            description=description,
            input_model=inp,
            output_model=out,
            handler=handler,
            risk=RiskLevel.LOW,
            data_classes=frozenset({DataClass.PERSONAL}),
            permission=PERMISSION,
            agents=AGENTS,
            mcp_group=GROUP,
            summarizer=summarizer,
            card=card,
        )

    return [
        spec(
            "vision.parse_photo_query",
            "Turn the owner's words (English, Hindi or Hinglish) into a PhotoQuery: dates in their time zone, "
            "colours, objects, screenshot or document hints, text to find. Next call device.photos.search with it.",
            ParseToolIn,
            ParsedQuery,
            parse,
            s.parse_summary,
            s.parse_card,
        ),
        spec(
            "vision.show_photo_results",
            "Present the photo identifiers the device returned for a PhotoQuery as a photo_query card.",
            ShowResultsIn,
            ShowResultsOut,
            show,
            s.show_summary,
            s.show_card,
        ),
    ]
