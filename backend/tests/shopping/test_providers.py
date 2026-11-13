from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import httpx
import pytest

from app.core.clock import FixedClock
from app.core.types import CapabilityStatus, IntegrationLevel
from app.shopping.config import ShoppingConfig, load_config, parse_config
from app.shopping.providers.base import ALL_METHODS, validate_levels
from app.shopping.providers.flipkart import FlipkartAffiliateProvider
from app.shopping.providers.hub import ProviderHub
from app.shopping.providers.swiggy import SwiggyInstamartProvider
from app.shopping.types import CartLine, ProviderMethod, SearchResults, Unavailable

from .conftest import NOW, SWIGGY_TOOLS, FakeMcpClient, raw_config

REPO_CONFIG = Path(__file__).resolve().parents[3] / "config"


def test_shipped_config_declares_every_method_for_every_provider() -> None:
    config = load_config(REPO_CONFIG)
    expected = {"swiggy_instamart", "flipkart_affiliate", "amazon_creators", "zepto", "blinkit", "bigbasket",
                "flipkart_minutes", "amazon_now", "amazon_in", "flipkart_web", "myntra"}  # fmt: skip
    assert set(config.providers) == expected
    hub = ProviderHub.from_config(
        config, env={}, mcp_client_factory=lambda pid, pc: FakeMcpClient(credentials=False)
    )
    for provider in hub.all():
        assert validate_levels(provider) == [], provider.id
        assert set(provider.levels) == set(ALL_METHODS)
        handoff = provider.handoff("atta")
        assert handoff is not None and handoff.url is not None and handoff.url.startswith("https://")
    swiggy = hub.get("swiggy_instamart")
    assert isinstance(swiggy, SwiggyInstamartProvider)
    assert not set(swiggy.config.tool_map.values()) & {"checkout", "confirm_order", "check_payment_status"}
    assert set(swiggy.config.tool_map.values()) <= set(SWIGGY_TOOLS)  # names from the official reference
    assert hub.get("amazon_creators") is not None
    assert all(v is IntegrationLevel.UNAVAILABLE for k, v in hub.get("amazon_creators").levels.items()  # type: ignore[union-attr]
               if k is not ProviderMethod.OPEN_PROVIDER_APP)  # fmt: skip


async def test_statuses_without_credentials(config: ShoppingConfig) -> None:
    hub = ProviderHub.from_config(
        config, env={}, mcp_client_factory=lambda pid, pc: FakeMcpClient(credentials=False)
    )
    statuses = await hub.refresh_status()
    assert statuses == {
        "swiggy_instamart": CapabilityStatus.REQUIRES_CREDENTIALS,
        "flipkart_affiliate": CapabilityStatus.REQUIRES_CREDENTIALS,
        "amazon_creators": CapabilityStatus.REQUIRES_PARTNERSHIP,
        "blinkit": CapabilityStatus.MANUAL_USER_STEP,
    }
    assert await hub.queryable() == []
    caps = {c.id: c for c in hub.capabilities()}
    assert caps["shopping.flipkart_affiliate"].requires == [
        "FLIPKART_AFFILIATE_ID",
        "FLIPKART_AFFILIATE_TOKEN",
    ]
    infos = {i.id: i for i in await hub.infos()}
    assert len(infos["swiggy_instamart"].methods) == len(ALL_METHODS)


def _swiggy(config: ShoppingConfig, client: FakeMcpClient) -> SwiggyInstamartProvider:
    return SwiggyInstamartProvider(
        "swiggy_instamart", config.providers["swiggy_instamart"], client, clock=FixedClock(NOW)
    )


async def test_swiggy_search_parses_official_shape(config: ShoppingConfig, fake_mcp: FakeMcpClient) -> None:
    swiggy = _swiggy(config, fake_mcp)
    result = await swiggy.search_products("atta", location_ref="addr_1")
    assert isinstance(result, SearchResults)
    assert fake_mcp.calls == [("search_products", {"query": "atta", "addressId": "addr_1"})]
    first = result.products[0]
    assert (first.provider, first.product_id, first.brand) == ("swiggy_instamart", "p_aash", "Aashirvaad")
    assert first.source == "swiggy_instamart:search_products" and first.retrieved_at == NOW
    assert [(v.variant_id, v.label, v.price_paise, v.sku_id) for v in first.variants] == [
        ("spin_a5", "5 kg", 28900, "sku_spin_a5"), ("spin_a10", "10 kg", 54900, "sku_spin_a10")]  # fmt: skip
    assert first.variants[0].pack is not None and first.variants[0].pack.total == 5000
    assert first.attributes["delivery_eta"] == "12 MINS"
    assert await swiggy.status() is CapabilityStatus.WORKING_INTEGRATION


async def test_swiggy_tool_mapping_mismatch_disables_calls(config: ShoppingConfig) -> None:
    client = FakeMcpClient(tools=[t for t in SWIGGY_TOOLS if t != "update_cart"])
    swiggy = _swiggy(config, client)
    report = await swiggy.connect()
    assert not report.ok and report.missing == ["update_cart"]
    result = await swiggy.search_products("atta")
    assert isinstance(result, Unavailable) and result.reason == "tool_mapping_mismatch"
    assert result.handoff is not None and result.handoff.url == "https://swiggy.example.test/instamart"
    assert client.calls == []
    assert await swiggy.status() is CapabilityStatus.UNAVAILABLE
    assert "update_cart" in swiggy.status_note()


async def test_swiggy_requires_credentials_and_handles_errors(config: ShoppingConfig) -> None:
    offline = FakeMcpClient(credentials=False)
    result = await _swiggy(config, offline).search_products("atta")
    assert isinstance(result, Unavailable) and result.reason == "requires_credentials"
    assert offline.list_calls == 0 and offline.calls == []

    failing = FakeMcpClient(responses={})  # every tool answers success=false
    result = await _swiggy(config, failing).search_products("atta")
    assert isinstance(result, Unavailable) and result.reason == "provider_error"

    class Boom(FakeMcpClient):
        async def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
            raise ConnectionError("down")

    result = await _swiggy(config, Boom()).search_products("atta")
    assert isinstance(result, Unavailable) and result.reason == "provider_unreachable"


def test_swiggy_refuses_order_or_payment_tools_in_mapping() -> None:
    raw = raw_config()
    raw["providers"]["swiggy_instamart"]["tool_map"]["update_cart"] = "checkout"
    config = parse_config(raw)
    with pytest.raises(ValueError, match="order or payment"):
        _swiggy(config, FakeMcpClient())


async def test_swiggy_cart_fees_and_prepare_checkout(config: ShoppingConfig, fake_mcp: FakeMcpClient) -> None:
    swiggy = _swiggy(config, fake_mcp)
    cart = await swiggy.get_cart()
    assert not isinstance(cart, Unavailable)
    assert cart.item_total_paise == 26500 and cart.to_pay_paise == 30400
    assert [(f.kind, f.amount_paise) for f in cart.fees] == [
        ("delivery_fee", 3000),
        ("handling_fee", 900),
        ("small_cart_fee", 0),
    ]
    assert ("Delivery Fee", "₹30") in cart.bill_lines

    no_address = await swiggy.add_to_cart([CartLine(product_id="p", variant_id="spin_p5", quantity=1)])
    assert isinstance(no_address, Unavailable) and no_address.reason == "address_required"

    prepared = await swiggy.prepare_checkout(
        [CartLine(product_id="p_pills", variant_id="spin_p5", sku_id="sku_spin_p5", quantity=1)],
        location_ref="addr_1",
    )
    assert not isinstance(prepared, Unavailable)
    assert prepared.cart_prepared and prepared.to_pay_paise == 30400
    assert prepared.handoff.url == "https://swiggy.example.test/instamart"
    assert ("update_cart", {"selectedAddressId": "addr_1",
            "items": [{"spinId": "spin_p5", "skuId": "sku_spin_p5", "quantity": 1}]}) in fake_mcp.calls  # fmt: skip
    assert all(name not in ("checkout", "confirm_order") for name, _ in fake_mcp.calls)
    unsupported = await swiggy.get_current_price("p_pills")
    assert isinstance(unsupported, Unavailable) and unsupported.reason == "not_supported"


FK_SEARCH = {
    "productInfoList": [
        {"productBaseInfoV1": {
            "productId": "MOBX1", "title": "Phone X (Blue, 128 GB)", "productBrand": "Acme",
            "maximumRetailPrice": {"amount": 19999.0, "currency": "INR"},
            "flipkartSellingPrice": {"amount": 15999.0, "currency": "INR"},
            "flipkartSpecialPrice": {"amount": 14999.0, "currency": "INR"},
            "inStock": True, "productUrl": "https://fk.example.test/p/MOBX1", "attributes": {"color": "Blue", "size": ""}}},
        {"productBaseInfoV1": {"title": "no id"}},
    ]
}  # fmt: skip


def _flipkart(
    config: ShoppingConfig, handler: Any, env: dict[str, str] | None = None
) -> FlipkartAffiliateProvider:
    return FlipkartAffiliateProvider(
        "flipkart_affiliate", config.providers["flipkart_affiliate"], clock=FixedClock(NOW),
        env=env if env is not None else {"FLIPKART_AFFILIATE_ID": "aff", "FLIPKART_AFFILIATE_TOKEN": "tok"},
        transport=httpx.MockTransport(handler),
    )  # fmt: skip


async def test_flipkart_affiliate_search_and_price(config: ShoppingConfig) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if request.url.path.endswith("/1.0/search.json"):
            return httpx.Response(200, json=FK_SEARCH)
        return httpx.Response(200, json=FK_SEARCH["productInfoList"][0])

    flipkart = _flipkart(config, handler)
    result = await flipkart.search_products("phone", limit=50)
    assert isinstance(result, SearchResults) and len(result.products) == 1
    assert seen[0].url.params["resultCount"] == "10" and seen[0].url.params["query"] == "phone"
    assert seen[0].headers["Fk-Affiliate-Id"] == "aff" and seen[0].headers["Fk-Affiliate-Token"] == "tok"
    variant = result.products[0].variants[0]
    assert (variant.price_paise, variant.mrp_paise, variant.in_stock) == (1499900, 1999900, True)
    assert result.products[0].attributes == {"color": "Blue"}
    price = await flipkart.get_current_price("MOBX1")
    assert not isinstance(price, Unavailable) and price.price_paise == 1499900
    assert price.source == "flipkart_affiliate:get_product_details"
    assert seen[-1].url.params["id"] == "MOBX1"
    assert await flipkart.status() is CapabilityStatus.WORKING_INTEGRATION
    delivery = await flipkart.get_delivery_estimate()
    assert isinstance(delivery, Unavailable) and delivery.reason == "not_supported"


async def test_flipkart_without_credentials_or_with_rejected_token(config: ShoppingConfig) -> None:
    def never(request: httpx.Request) -> httpx.Response:
        raise AssertionError("must not call the network")

    result = await _flipkart(config, never, env={}).search_products("phone")
    assert isinstance(result, Unavailable) and result.reason == "requires_credentials"
    assert result.handoff is not None and result.handoff.url == "https://fk.example.test/search?q=phone"

    rejected = await _flipkart(config, lambda r: httpx.Response(401)).search_products("phone")
    assert isinstance(rejected, Unavailable) and rejected.reason == "credentials_rejected"
    malformed = await _flipkart(config, lambda r: httpx.Response(200, content=b"<xml/>")).search_products("x")
    assert isinstance(malformed, Unavailable) and malformed.reason == "malformed_response"
    shape = await _flipkart(
        config, lambda r: httpx.Response(200, content=json.dumps({"x": 1}))
    ).search_products("x")
    assert isinstance(shape, Unavailable) and shape.reason == "malformed_response"


async def test_handoff_and_partnership_providers_never_guess(config: ShoppingConfig) -> None:
    hub = ProviderHub.from_config(config, env={}, mcp_client_factory=lambda pid, pc: FakeMcpClient())
    blinkit = await hub.get("blinkit").search_products("amul butter")  # type: ignore[union-attr]
    assert isinstance(blinkit, Unavailable) and blinkit.reason == "handoff_only"
    assert (
        blinkit.handoff is not None and blinkit.handoff.url == "https://blinkit.example.test/s/?q=amul+butter"
    )
    assert blinkit.handoff.verified is False
    amazon = await hub.get("amazon_creators").search_products("x")  # type: ignore[union-attr]
    assert isinstance(amazon, Unavailable) and amazon.reason == "requires_partnership"
    for method in (m for m in ALL_METHODS if m is not ProviderMethod.OPEN_PROVIDER_APP):
        assert hub.get("blinkit").level(method) in (  # type: ignore[union-attr]
            IntegrationLevel.UNAVAILABLE, IntegrationLevel.DEEP_LINK_HANDOFF)  # fmt: skip
    opened = await hub.get("blinkit").open_provider_app()  # type: ignore[union-attr]
    assert not isinstance(opened, Unavailable) and opened.url == "https://blinkit.example.test/"
