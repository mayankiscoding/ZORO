"""Finance and shopping journeys: an exact spending figure in three languages, and a shopping
conversation that keeps its context and refuses to name a cheapest store it cannot prove."""

from __future__ import annotations

from datetime import date
from decimal import Decimal
from typing import Any

import pytest

from app.plugins import PluginRegistry
from tests.finance.samples import Row, generic_csv
from tests.integration.flows.conftest import ExternalGateway, Phone, in_order
from tests.shopping.conftest import CART, SEARCH_ATTA, FakeMcpClient

D = Decimal

# A synthetic statement (tests only). Food in October 2026: 812.50 + 431.25 = 1,243.75.
STATEMENT: list[Row] = [
    (date(2026, 9, 28), "UPI/DR/427500000001/SWIGGY/YESB/swiggy@ybl/Payment", None, D("999.00"), None),
    (date(2026, 10, 1), "NEFT CR-HDFC0000001-ACME CORP-SALARY", None, None, D("90000.00")),
    (date(2026, 10, 4), "UPI/DR/427500000002/SWIGGY/YESB/swiggy@ybl/Payment", None, D("812.50"), None),
    (date(2026, 10, 9), "ECOM PUR/AMAZON/BANGALORE", None, D("2300.00"), None),
    (date(2026, 10, 18), "UPI/DR/427500000003/ZOMATO/YESB/zomato@ybl/Payment", None, D("431.25"), None),
    (date(2026, 10, 21), "UPI/DR/427500000004/UBER/YESB/uber@ybl/Payment", None, D("260.00"), None),
    (date(2026, 11, 3), "UPI/DR/427500000005/ZOMATO/YESB/zomato@ybl/Payment", None, D("555.00"), None),
]


# ---------------------------------------------------------------- (a) spending


@pytest.mark.parametrize(
    ("lang", "question"),
    [
        ("en", "how much did I spend on food last month"),
        ("hi", "पिछले महीने खाने पर कितना खर्च हुआ"),
        ("hinglish", "pichhle mahine khane pe kitna kharch hua"),
    ],
)
async def test_food_spending_last_month_is_exact_in_three_languages(
    phone: Phone, gateway: ExternalGateway, lang: str, question: str
) -> None:
    uploaded = await phone.client.post(
        "/v1/finance/imports",
        headers=phone.device.headers,
        files={"file": ("october.csv", generic_csv(STATEMENT), "text/csv")},
        data={"account_name": "Main"},
    )
    assert uploaded.status_code in (200, 201), uploaded.text

    turn = await phone.ask(question)

    assert turn.kinds[0] == "turn_started" and turn.kinds[-1] == "turn_completed"
    assert in_order(
        turn.kinds,
        "turn_started", "route", "agent_started", "tool_started", "tool_finished", "agent_finished",
        "text_delta", "turn_completed",
    )  # fmt: skip
    assert turn.tools == ["finance.spending_summary"]
    route = turn.of("route")[0]
    assert route["agents"] == ["finance"] and route["engine"] == "deterministic"
    assert "financial" in route["data_classes"]
    card = next(card for card in turn.cards if card["kind"] == "finance_summary")
    assert card["payload"]["spent"] == "1243.75"  # a decimal string, computed by code
    assert card["payload"]["transactions"] == 2 and card["payload"]["period"]["start"] == "2026-10-01"
    assert "1,243.75" in turn.text  # the exact figure, spoken
    done = turn.of("turn_completed")[0]
    assert done["language"] == lang and done["cloud_voice_allowed"] is False
    assert done["usage"]["model_calls"] == 0 and gateway.requests == []


# ---------------------------------------------------------------- (f) shopping


def use_fake_store(registry: PluginRegistry) -> FakeMcpClient:
    """Put a fake store behind the Swiggy Instamart provider (its MCP client), as the provider
    tests do. Prices below are sample data and exist only in tests."""
    fake = FakeMcpClient(responses={"search_products": SEARCH_ATTA, "get_cart": CART, "update_cart": CART})
    provider = registry.service("shopping").hub.get("swiggy_instamart")
    assert provider is not None
    provider._client = fake
    return fake


async def test_shopping_conversation_keeps_context_and_never_guesses_a_cheapest_store(
    phone: Phone, registry: PluginRegistry, gateway: ExternalGateway
) -> None:
    fake = use_fake_store(registry)
    await registry.service("shopping").hub.refresh_status()

    search = await phone.ask("search for atta")
    assert search.tools == ["shopping.search_products"] and search.completed
    assert [name for name, _ in fake.calls] == ["search_products"]
    conversation = search.conversation_id
    products = next(card for card in search.cards if card["kind"] == "products")["payload"]["products"]
    second = products[1]
    assert second["source"] == "swiggy_instamart:search_products" and second["retrieved_at"]  # provenance

    added = await phone.ask("add the second one", conversation_id=conversation)
    assert added.tools == ["shopping.basket_add"] and added.completed
    basket = await _basket(phone)
    assert [(item["name"], item["quantity"]) for item in basket["items"]] == [(second["name"], 1)]

    # "add two more" names no product. The call still runs (its slots carry only the reference)
    # so the tool can ask; with three products on screen it asks rather than guess.
    vague = await phone.ask("add two more", conversation_id=conversation)
    assert vague.tools == ["shopping.basket_add"] and vague.completed
    assert vague.text == "Which one do you mean?"
    basket = await _basket(phone)
    assert [(item["name"], item["quantity"]) for item in basket["items"]] == [(second["name"], 1)]

    more = await phone.ask("add two more of the second one", conversation_id=conversation)
    assert more.tools == ["shopping.basket_add"] and more.completed
    basket = await _basket(phone)
    assert [(item["name"], item["quantity"]) for item in basket["items"]] == [(second["name"], 3)]
    assert "3" in more.text and second["name"] in more.text

    compared = await phone.ask("compare this basket", conversation_id=conversation)
    assert compared.tools == ["shopping.compare_basket"] and compared.completed
    (card,) = compared.cards
    comparison = card["payload"]
    assert comparison["cheapest_provider"] is None  # no store is called cheapest without full coverage
    assert comparison["cheapest_reason"] in ("no_complete_provider", "fees_unknown"), comparison
    assert "cheapest for the full basket" not in compared.text and "sabse sasti" not in compared.text
    assert gateway.requests == []


async def _basket(phone: Phone) -> dict[str, Any]:
    response = await phone.client.get("/v1/shopping/baskets", headers=phone.device.headers)
    assert response.status_code == 200, response.text
    body: Any = response.json()
    basket: dict[str, Any] = body[0] if isinstance(body, list) else body.get("basket", body)
    return basket
