"""HTTP routes of the model gateway (mounted under /v1 by the plugin registry). No business logic here."""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query

from app.core.types import PrivacyMode
from app.providers.gateway import ModelGateway
from app.providers.usage import GroupBy, SessionFactory, cost_summary
from app.schemas.security import CostSummary, ModelRouteInfo


def build_router(
    gateway: ModelGateway,
    session_factory: SessionFactory,
    require_device: Callable[..., Any],
) -> APIRouter:
    router = APIRouter(tags=["models"], dependencies=[Depends(require_device)])

    @router.get("/costs/summary", response_model=CostSummary)
    async def get_cost_summary(
        group_by: GroupBy = "model",
        since: Annotated[datetime | None, Query()] = None,
        until: Annotated[datetime | None, Query()] = None,
    ) -> CostSummary:
        return await cost_summary(session_factory, group_by, since=since, until=until)

    @router.get("/models/routes", response_model=list[ModelRouteInfo])
    async def get_model_routes(
        privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE,
    ) -> list[ModelRouteInfo]:
        return await gateway.route_info(privacy_mode)

    return router
