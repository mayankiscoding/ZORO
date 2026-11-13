"""Registers the shopping package: providers, services, tools, intents, routes, capabilities, permissions."""

from __future__ import annotations

import os
from collections.abc import Mapping
from typing import Any

from app.shopping.basket import BasketService
from app.shopping.config import ProviderConfig, ShoppingConfig, load_config
from app.shopping.intents import INTENTS
from app.shopping.providers.hub import CALLBACK_PATH, McpClientFactory, ProviderHub
from app.shopping.service import ShoppingService
from app.shopping.shortlist import ShortlistService
from app.shopping.tools_basket import build_basket_tools
from app.shopping.tools_catalog import build_catalog_tools
from app.shopping.tools_common import PERM_BASKET, PERM_PROVIDER_CART


def _sdk_factory(reg: Any, flows: dict[str, Any]) -> McpClientFactory:
    """Real MCP clients (tokens in SecretStore). Imported lazily: tests inject fakes instead."""
    from app.shopping.providers.mcp_client import ConnectFlow, SdkMcpClient, SecretTokenStorage

    settings = reg.service("settings")

    def make(provider_id: str, pc: ProviderConfig) -> Any:
        redirect = pc.oauth_redirect_uri or (
            str(settings.public_base_url).rstrip("/") + CALLBACK_PATH.format(provider=provider_id)
        )
        storage = SecretTokenStorage(reg.service("secrets"), provider_id)
        flows[provider_id] = ConnectFlow(pc.mcp_url or "", storage, redirect)
        return SdkMcpClient(pc.mcp_url or "", storage, redirect)

    return make


def register(
    reg: Any,
    *,
    config: ShoppingConfig | None = None,
    env: Mapping[str, str] | None = None,
    mcp_client_factory: McpClientFactory | None = None,
) -> None:
    from app.api.deps import require_device
    from app.shopping.api import build_router

    settings = reg.service("settings")
    clock = reg.service("clock")
    session_factory = reg.service("session_factory")
    config = config or load_config(settings.config_dir)
    flows: dict[str, Any] = {}
    factory = mcp_client_factory or _sdk_factory(reg, flows)
    hub = ProviderHub.from_config(
        config, clock=clock, env=os.environ if env is None else env, mcp_client_factory=factory
    )
    baskets = BasketService(session_factory, clock)
    shortlist = ShortlistService(session_factory, clock)
    service = ShoppingService(config, hub, baskets, shortlist, clock)

    reg.provide("shopping", service)
    reg.provide("shopping_shortlist", shortlist)
    reg.add_permission(PERM_BASKET, "Keep a shopping basket and shortlist", True)
    reg.add_permission(PERM_PROVIDER_CART, "Fill your cart in a shopping provider's account", False)
    for spec in [*build_catalog_tools(service), *build_basket_tools(service)]:
        reg.add_tool(spec)
    for intent in INTENTS:
        reg.add_intent(intent)
    for router in build_router(service, flows, require_device):
        reg.add_router(router)
    reg.add_capability(hub.capabilities)
    reg.add_startup(hub.refresh_status)
    reg.add_shutdown(hub.aclose)
