"""Shopping tests: a fresh kernel registry with only the shopping plugin, a fixed clock, a fake
Swiggy MCP client and sample data (sample data lives only under tests/). Nothing touches the network."""

from __future__ import annotations

from collections.abc import AsyncIterator, Callable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

import pytest

from app.core.clock import FixedClock
from app.core.settings import Settings
from app.core.types import AgentId, DevicePlatform
from app.db.discovery import model_packages
from app.plugins import PluginRegistry, build_kernel
from app.shopping import plugin as shopping_plugin
from app.shopping.config import ShoppingConfig, parse_config
from app.shopping.providers.swiggy import McpCallResult, McpToolInfo
from app.tools.spec import ToolContext
from tests.fakes.devices import DeviceSigner

NOW = datetime(2026, 11, 13, 10, 0, 0, tzinfo=UTC)
SWIGGY_TOOLS = [
    "create_address", "delete_address", "get_addresses", "search_products", "your_go_to_items", "clear_cart",
    "get_cart", "update_cart", "check_payment_status", "confirm_order", "get_payment_options", "checkout",
    "get_delivery_status", "get_orders", "track_order", "report_error",
]  # fmt: skip


def raw_config() -> dict[str, Any]:
    return {
        "staleness_minutes": {"provider_api": 30, "user_reported": 1440, "user_screenshot_ocr": 720},
        "providers": {
            "swiggy_instamart": {
                "title": "Swiggy Instamart", "kind": "mcp", "category": "quick_commerce",
                "mcp_url": "https://mcp.example.test/im",
                "tool_map": {"search_products": "search_products", "get_cart": "get_cart",
                             "update_cart": "update_cart"},
                "forbidden_tools": ["checkout", "confirm_order"],
                "handoff": {"url": "https://swiggy.example.test/instamart", "verified": False},
            },
            "flipkart_affiliate": {
                "title": "Flipkart (Affiliate API)", "kind": "flipkart_affiliate",
                "base_url": "https://fk.example.test/affiliate", "endpoints_verified": True,
                "credential_env": ["FLIPKART_AFFILIATE_ID", "FLIPKART_AFFILIATE_TOKEN"],
                "handoff": {"url": "https://fk.example.test/search?q={query}"},
            },
            "amazon_creators": {
                "title": "Amazon (Creators API)", "kind": "partnership", "partnership_note": "Needs 10 sales.",
                "handoff": {"url": "https://amazon.example.test/s?k={query}"},
            },
            "blinkit": {
                "title": "Blinkit", "kind": "handoff", "category": "quick_commerce",
                "handoff": {"url": "https://blinkit.example.test/s/?q={query}", "verified": False},
            },
        },
    }  # fmt: skip


def swiggy_product(
    pid: str, name: str, brand: str, variants: list[tuple[str, str, str, bool]]
) -> dict[str, Any]:
    """variants: (spinId, quantityDescription, offerPrice, in stock)."""
    return {
        "productId": pid, "parentProductId": pid, "displayName": name, "brand": brand,
        "inStock": True, "isAvail": True,
        "variations": [
            {"spinId": spin, "skuId": f"sku_{spin}", "quantityDescription": qty, "displayName": name,
             "brandName": brand, "price": {"mrp": price, "offerPrice": price},
             "isInStockAndAvailable": stock, "sla": {"value": "12", "unit": "MINS"}}
            for spin, qty, price, stock in variants
        ],
    }  # fmt: skip


SEARCH_ATTA = {
    "success": True,
    "data": {
        "nextOffset": "1",
        "products": [
            swiggy_product("p_aash", "Aashirvaad Shudh Chakki Atta", "Aashirvaad",
                           [("spin_a5", "5 kg", "289", True), ("spin_a10", "10 kg", "549", True)]),
            swiggy_product("p_pills", "Pillsbury Chakki Fresh Atta", "Pillsbury", [("spin_p5", "5 kg", "265", True)]),
            swiggy_product("p_milk", "Amul Taaza Toned Milk", "Amul", [("spin_m1", "500 ml", "29", True)]),
        ],
    },
}  # fmt: skip

CART = {
    "success": True,
    "data": {
        "cartTotalAmount": "330",
        "items": [{"spinId": "spin_p5", "skuId": "sku_spin_p5", "productId": "p_pills", "itemName": "Pillsbury",
                   "quantity": 1, "isInStockAndAvailable": True, "mrp": 265, "discountedFinalPrice": 265}],
        "billBreakdown": {
            "lineItems": [{"label": "Item Total", "value": "₹265"}, {"label": "Delivery Fee", "value": "₹30"},
                          {"label": "Handling Fee", "value": "₹9"}, {"label": "Small Cart Fee", "value": "FREE"}],
            "toPay": {"label": "To Pay", "value": "₹304"},
        },
    },
}  # fmt: skip


@dataclass
class FakeMcpClient:
    tools: list[str] = field(default_factory=lambda: list(SWIGGY_TOOLS))
    credentials: bool = True
    responses: dict[str, Any] = field(default_factory=dict)
    calls: list[tuple[str, dict[str, Any]]] = field(default_factory=list)
    list_calls: int = 0

    async def has_credentials(self) -> bool:
        return self.credentials

    async def list_tools(self) -> list[McpToolInfo]:
        self.list_calls += 1
        return [McpToolInfo(name=n) for n in self.tools]

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> McpCallResult:
        self.calls.append((name, arguments))
        response = self.responses.get(name)
        if callable(response):
            response = response(arguments)
        if response is None:
            return McpCallResult(text='{"success": false, "error": {"message": "no"}}', is_error=True)
        return McpCallResult(structured=response)


@pytest.fixture
def config() -> ShoppingConfig:
    return parse_config(raw_config())


@pytest.fixture
def fake_mcp() -> FakeMcpClient:
    return FakeMcpClient(responses={"search_products": SEARCH_ATTA, "get_cart": CART, "update_cart": CART})


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(NOW)


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ()


@pytest.fixture
async def shop(
    settings: Settings, clock: FixedClock, config: ShoppingConfig, fake_mcp: FakeMcpClient
) -> AsyncIterator[PluginRegistry]:
    """A fresh registry: kernel services + the shopping plugin only (tables created)."""
    reg = build_kernel(settings, clock=clock)
    await reg.service("database").init(packages=model_packages(("app.shopping.plugin",)))
    shopping_plugin.register(reg, config=config, env={}, mcp_client_factory=lambda pid, pc: fake_mcp)
    await reg.run_startup()
    yield reg
    await reg.run_shutdown()
    await reg.service("database").dispose()


@dataclass
class Owner:
    device_id: str
    signer: DeviceSigner


@pytest.fixture
async def owner(shop: PluginRegistry, clock: FixedClock) -> Owner:
    signer = DeviceSigner(name="Test iPhone", platform=DevicePlatform.IOS, now=clock.now)
    issued = await shop.service("devices").create_pairing_code()
    record = await shop.service("devices").pair(signer.pair_request(issued.code, []))
    signer.device_id = record.id
    return Owner(device_id=record.id, signer=signer)


CtxFactory = Callable[..., ToolContext]


@pytest.fixture
def make_ctx(shop: PluginRegistry, owner: Owner) -> CtxFactory:
    def _make(**overrides: Any) -> ToolContext:
        fields: dict[str, Any] = {
            "turn_id": "turn_1", "agent": AgentId.SHOPPING, "device_id": owner.device_id,
            "conversation_id": "conv_1", "user_initiated": True,
        }  # fmt: skip
        fields.update(overrides)
        ctx: ToolContext = shop.tool_context(**fields)
        return ctx

    return _make
