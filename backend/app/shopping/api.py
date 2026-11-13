"""HTTP routes under /v1/shopping. Every action runs its tool through the executor (`http.run_tool`)."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field

from app.api.deps import CurrentDevice, Registry
from app.core.errors import BadRequest, NotFound
from app.core.types import AgentId
from app.shopping.basket import PriceRecord
from app.shopping.http import ToolRun, run_tool
from app.shopping.service import ShoppingService
from app.shopping.tools_basket import BasketAddIn
from app.shopping.tools_catalog import CheckoutIn, CompareIn, SearchIn
from app.shopping.tools_common import ProductPick
from app.shopping.types import ProviderInfo

AGENT = AgentId.SHOPPING


class QuantityBody(BaseModel):
    quantity: int = Field(ge=1, le=99)


class ConnectStarted(BaseModel):
    provider: str
    authorization_url: str  # empty when the account was already connected


class ConnectFinished(BaseModel):
    provider: str
    connected: bool


async def _result(
    reg: Any, device: Any, tool: str, args: Any, conversation_id: str | None = None
) -> dict[str, Any]:
    run = await run_tool(reg, device.device_id, tool, args, agent=AGENT, conversation_id=conversation_id)
    return run.result or {}


def build_router(svc: ShoppingService, connect_flows: dict[str, Any], require_device: Any) -> list[APIRouter]:
    router = APIRouter(prefix="/shopping", tags=["shopping"], dependencies=[Depends(require_device)])

    @router.get("/providers", response_model=list[ProviderInfo])
    async def providers() -> list[ProviderInfo]:
        return await svc.hub.infos()

    @router.post("/providers/{provider_id}/connect", response_model=ConnectStarted)
    async def connect(provider_id: str) -> ConnectStarted:
        flow = connect_flows.get(provider_id)
        if flow is None:
            raise NotFound("This provider has no account connection.", code="no_connect_flow")
        return ConnectStarted(provider=provider_id, authorization_url=await flow.start())

    @router.post("/search")
    async def search(
        body: SearchIn, reg: Registry, device: CurrentDevice, conversation_id: str | None = None
    ) -> dict[str, Any]:
        return await _result(reg, device, "shopping.search_products", body, conversation_id)

    @router.get("/baskets")
    async def basket(reg: Registry, device: CurrentDevice, basket_id: str | None = None) -> dict[str, Any]:
        return await _result(reg, device, "shopping.basket_view", {"basket_id": basket_id})

    @router.post("/baskets/items")
    async def add_item(
        body: BasketAddIn, reg: Registry, device: CurrentDevice, conversation_id: str = Query(...)
    ) -> dict[str, Any]:
        return await _result(reg, device, "shopping.basket_add", body, conversation_id)

    @router.patch("/items/{item_id}")
    async def set_quantity(
        item_id: str, body: QuantityBody, reg: Registry, device: CurrentDevice
    ) -> dict[str, Any]:
        return await _result(
            reg, device, "shopping.basket_set_quantity", {"item_id": item_id, "quantity": body.quantity}
        )

    @router.delete("/items/{item_id}")
    async def remove_item(item_id: str, reg: Registry, device: CurrentDevice) -> dict[str, Any]:
        return await _result(reg, device, "shopping.basket_remove", {"item_id": item_id})

    @router.post("/observations")
    async def record(body: PriceRecord, reg: Registry, device: CurrentDevice) -> dict[str, Any]:
        return await _result(reg, device, "shopping.record_price", body)

    @router.post("/compare")
    async def compare(body: CompareIn, reg: Registry, device: CurrentDevice) -> dict[str, Any]:
        return await _result(reg, device, "shopping.compare_basket", body)

    @router.post("/checkout", response_model=ToolRun)
    async def checkout(body: CheckoutIn, reg: Registry, device: CurrentDevice) -> ToolRun:
        return await run_tool(reg, device.device_id, "shopping.prepare_checkout", body, agent=AGENT)

    @router.post("/shortlist")
    async def shortlist_add(
        body: ProductPick, reg: Registry, device: CurrentDevice, conversation_id: str = Query(...)
    ) -> dict[str, Any]:
        return await _result(reg, device, "shopping.shortlist_add", body, conversation_id)

    @router.get("/shortlist")
    async def shortlist() -> list[dict[str, Any]]:
        return [e.model_dump(mode="json") for e in await svc.shortlist.list()]

    # The provider's OAuth redirect lands here from the owner's browser (no device token there).
    # It only completes a flow a paired device started; the SDK checks the OAuth `state`.
    callback = APIRouter(prefix="/shopping", tags=["shopping"])

    @callback.get("/providers/{provider_id}/oauth/callback", response_model=ConnectFinished)
    async def oauth_callback(
        provider_id: str,
        code: str = Query(..., max_length=2048),
        state: str | None = Query(None, max_length=512),
    ) -> ConnectFinished:
        flow = connect_flows.get(provider_id)
        if flow is None or not flow.pending:
            raise BadRequest("No connection is waiting for this provider.", code="no_pending_connect")
        connected = await flow.finish(code, state)
        await svc.hub.refresh_status()
        return ConnectFinished(provider=provider_id, connected=connected)

    return [router, callback]
