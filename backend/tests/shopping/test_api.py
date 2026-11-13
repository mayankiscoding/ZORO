"""Routes through the real app with the shipped config. No account is connected and no credential
is set, so nothing reaches the network: Swiggy reads requires_credentials, others hand off."""

from __future__ import annotations

from collections.abc import Sequence

import httpx
import pytest

from app.core.clock import Clock, SystemClock
from tests.conftest import PairedDevice


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.shopping.plugin", "app.research.plugin")


@pytest.fixture
def clock() -> Clock:
    return SystemClock()


@pytest.fixture(autouse=True)
def _no_flipkart_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("FLIPKART_AFFILIATE_ID", raising=False)
    monkeypatch.delenv("FLIPKART_AFFILIATE_TOKEN", raising=False)


async def test_providers_route_lists_levels_per_method(
    client: httpx.AsyncClient, paired_device: PairedDevice
) -> None:
    assert (await client.get("/v1/shopping/providers")).status_code == 401
    response = await client.get("/v1/shopping/providers", headers=paired_device.headers)
    assert response.status_code == 200
    providers = {p["id"]: p for p in response.json()}
    assert providers["swiggy_instamart"]["status"] == "requires_credentials"
    assert providers["amazon_creators"]["status"] == "requires_partnership"
    assert providers["zepto"]["status"] == "manual_user_step"
    assert all(len(p["methods"]) == 12 for p in providers.values())
    levels = {m["method"]: m["level"] for m in providers["swiggy_instamart"]["methods"]}
    assert levels["search_products"] == "official_api" and levels["get_current_price"] == "unavailable"

    caps = (await client.get("/v1/capabilities", headers=paired_device.headers)).json()
    ids = {c["id"]: c["status"] for c in (caps["items"] if isinstance(caps, dict) else caps)}
    assert ids["shopping.flipkart_affiliate"] == "requires_credentials"
    assert ids["research.web_search"] == "requires_credentials"


async def test_search_basket_and_checkout_routes(
    client: httpx.AsyncClient, paired_device: PairedDevice
) -> None:
    h = paired_device.headers
    found = await client.post(
        "/v1/shopping/search?conversation_id=conv_api", json={"query": "atta"}, headers=h
    )
    assert found.status_code == 200
    body = found.json()
    assert body["products"] == []
    assert {u["provider"]: u["reason"] for u in body["unavailable"]}[
        "swiggy_instamart"
    ] == "requires_credentials"
    zepto = next(u for u in body["unavailable"] if u["provider"] == "zepto")
    assert (
        zepto["handoff"]["url"] == "https://www.zeptonow.com/search?query=atta"
        and zepto["handoff"]["verified"] is False
    )

    basket = await client.get("/v1/shopping/baskets", headers=h)
    assert basket.status_code == 200 and basket.json() == {"basket": None}
    missing = await client.patch("/v1/shopping/items/bki_nope", json={"quantity": 2}, headers=h)
    assert missing.status_code == 400 and missing.json()["code"] == "basket_item_not_found"
    checkout = await client.post(
        "/v1/shopping/checkout", json={"provider": "swiggy_instamart", "expected_payable": "10.00"}, headers=h
    )
    assert (
        checkout.status_code == 403
        and checkout.json()["code"] == "permission_not_granted:shopping.provider_cart"
    )
    callback = await client.get("/v1/shopping/providers/swiggy_instamart/oauth/callback?code=x&state=y")
    assert callback.status_code == 400 and callback.json()["code"] == "no_pending_connect"


async def test_research_routes(client: httpx.AsyncClient, paired_device: PairedDevice) -> None:
    h = paired_device.headers
    blocked = await client.post("/v1/research/fetch", json={"url": "https://127.0.0.1/admin"}, headers=h)
    assert blocked.status_code == 200 and blocked.json()["error"] == "blocked_address"
    plain = await client.post("/v1/research/fetch", json={"url": "http://example.org/"}, headers=h)
    assert plain.json()["error"] == "https_only"
    search = await client.post("/v1/research/search", json={"query": "x"}, headers=h)
    assert search.json()["status"] == "unavailable" and search.json()["reason"] == "requires_credentials"
    empty = await client.post("/v1/research/compare-shortlist", json={}, headers=h)
    assert empty.json()["status"] == "empty"
