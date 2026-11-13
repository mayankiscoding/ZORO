"""`/v1/vision`: one JSON route that turns words into a `PhotoQuery`. There is deliberately no route that
accepts an image, a file or bytes: photos are searched on the device and only identifiers come back."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any

from fastapi import APIRouter, Depends

from app.core.errors import Forbidden
from app.vision.schemas import ParsedQuery, ParseIn
from app.vision.service import VisionService

PERMISSION = "vision.search"


def build_router(reg: Any, svc: VisionService, require_device: Callable[..., Awaitable[Any]]) -> APIRouter:
    router = APIRouter(prefix="/vision", tags=["vision"], dependencies=[Depends(require_device)])

    async def can_search() -> None:
        if not await reg.service("permissions").is_granted(PERMISSION):
            raise Forbidden(
                f"Allow '{PERMISSION}' in Security and privacy first.",
                code=f"permission_not_granted:{PERMISSION}",
            )

    @router.post("/parse-query", response_model=ParsedQuery, dependencies=[Depends(can_search)])
    async def parse_query(body: ParseIn) -> ParsedQuery:
        mode = await reg.service("privacy_state").get_mode()
        return await svc.parse(
            body.text, reg.service("clock").now(), body.timezone, refine=body.refine, privacy_mode=mode
        )

    return router
