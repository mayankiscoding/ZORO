from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from typing import Any

from app.core.clock import FixedClock
from app.core.types import AgentId, ApprovalLevel, RiskLevel
from app.plugins import PluginRegistry
from app.shopping.intents import extract_add, extract_search
from app.tools.executor import ToolExecutor
from app.tools.intents import IntentContext
from app.tools.outcome import Completed, Denied, NeedsApproval

from .conftest import NOW, CtxFactory, FakeMcpClient, Owner

TOOLS = {
    "shopping.search_products": RiskLevel.LOW, "shopping.product_details": RiskLevel.LOW,
    "shopping.basket_view": RiskLevel.LOW, "shopping.compare_basket": RiskLevel.LOW,
    "shopping.basket_add": RiskLevel.MEDIUM, "shopping.basket_set_quantity": RiskLevel.MEDIUM,
    "shopping.basket_remove": RiskLevel.MEDIUM, "shopping.record_price": RiskLevel.MEDIUM,
    "shopping.shortlist_add": RiskLevel.MEDIUM, "shopping.prepare_checkout": RiskLevel.HIGH,
}  # fmt: skip


async def run(shop: PluginRegistry, ctx: Any, tool: str, args: dict[str, Any], call_id: str) -> Any:
    executor: ToolExecutor = shop.service("tool_executor")
    return await executor.execute(ctx, tool, args, call_id=call_id)


async def done(shop: PluginRegistry, ctx: Any, tool: str, args: dict[str, Any], call_id: str) -> Completed:
    outcome = await run(shop, ctx, tool, args, call_id)
    assert isinstance(outcome, Completed), outcome
    return outcome


def test_registration_is_complete(shop: PluginRegistry) -> None:
    for name, risk in TOOLS.items():
        spec = shop.tools.get(name)
        assert spec is not None and spec.risk is risk and spec.mcp_group == "shopping-mcp"
        assert spec.summarizer is not None and spec.agents
    assert shop.tools.get("shopping.search_products").untrusted_output  # type: ignore[union-attr]
    for intent in shop.intents.all():
        assert set(intent.keywords) == {"en", "hi", "hinglish"}
    assert {c.id for c in shop.capabilities.all(domain="shopping")} >= {
        "shopping.swiggy_instamart",
        "shopping.blinkit",
    }


async def search(shop: PluginRegistry, make_ctx: CtxFactory) -> Completed:
    ctx = make_ctx(turn_id="turn_search")
    out = await done(shop, ctx, "shopping.search_products", {"query": "atta"}, "c_search")
    assert out.untrusted and ctx.tainted  # MCP results are untrusted data
    return out


async def test_search_then_ordinal_add_in_three_languages(shop: PluginRegistry, make_ctx: CtxFactory) -> None:
    out = await search(shop, make_ctx)
    result = out.result
    assert [p.index for p in result.products] == [1, 2, 3]
    assert {u.provider: u.reason for u in result.unavailable} == {
        "flipkart_affiliate": "requires_credentials", "amazon_creators": "requires_partnership",
        "blinkit": "handoff_only"}  # fmt: skip
    assert out.summary == "Found 3 products for “atta”. The lowest price is ₹29.00."
    assert out.card is not None and out.card.kind == "products"
    spec = shop.tools.get("shopping.search_products")
    assert spec is not None and spec.summarizer is not None
    assert spec.summarizer(result, "hi") == "“atta” के लिए 3 उत्पाद मिले। सबसे कम कीमत ₹29.00 है।"
    assert (
        spec.summarizer(result, "hinglish") == "“atta” ke liye 3 products mile. Sabse kam price ₹29.00 hai."
    )

    # next turn (not tainted): "doosra wala add karo" -> the second product shown
    added = await done(shop, make_ctx(turn_id="t2", lang="hinglish"), "shopping.basket_add",
                       {"reference": "doosra wala add karo"}, "c_add1")  # fmt: skip
    item = added.result.item
    assert (
        added.result.status == "added" and item.name == "Pillsbury Chakki Fresh Atta" and item.quantity == 1
    )
    assert item.unit_price == Decimal("265.00") and item.price_source == "swiggy_instamart:search_products"
    assert added.summary == "Basket mein ab Pillsbury Chakki Fresh Atta ki quantity 1 hai."

    # "add two more packets" with three products shown: ask, never guess
    vague = await done(
        shop, make_ctx(turn_id="t3"), "shopping.basket_add", {"reference": "add two more packets"}, "c_add2"
    )
    assert vague.result.status == "needs_clarification" and len(vague.result.clarification.options) == 3
    assert vague.summary == "Which one do you mean?"

    # "दूसरा वाला, दो और" -> the same product, quantity + 2
    more = await done(shop, make_ctx(turn_id="t4", lang="hi"), "shopping.basket_add",
                      {"reference": "दूसरा वाला दो और पैकेट", "quantity": 2}, "c_add3")  # fmt: skip
    assert more.result.status == "updated" and more.result.item.quantity == 3
    assert more.summary == "टोकरी में अब Pillsbury Chakki Fresh Atta की मात्रा 3 है।"

    # the first product has two sizes: ask which, then take the size hint
    sizes = await done(
        shop, make_ctx(turn_id="t5"), "shopping.basket_add", {"reference": "the first one"}, "c_add4"
    )
    assert sizes.result.status == "needs_clarification"
    assert [o["label"] for o in sizes.result.clarification.options] == ["5 kg", "10 kg"]
    ten = await done(shop, make_ctx(turn_id="t6"), "shopping.basket_add",
                     {"reference": "the first one", "variant_hint": "10 kg"}, "c_add5")  # fmt: skip
    assert ten.result.item.size == "10 kg" and ten.result.item.unit_price == Decimal("549.00")
    assert ten.card is not None and ten.card.kind == "basket"


def test_intent_slots_use_the_working_set() -> None:
    items = [{"ref": "s:p1", "label": "A"}, {"ref": "s:p2", "label": "B"}]
    ctx = IntentContext(lang="hinglish", now=NOW, working_sets={"products": items})
    assert extract_add("doosra wala add karo", ctx) == {"ref": "s:p2", "reference": "doosra wala add karo"}
    hi = IntentContext(lang="hi", now=NOW, working_sets={"products": items})
    assert extract_add("दूसरा वाला जोड़ो", hi)["ref"] == "s:p2"  # type: ignore[index]
    assert extract_add("add two more packets", ctx) == {"reference": "add two more packets", "quantity": 2}
    assert extract_add("add two more", IntentContext(lang="en", now=NOW)) is None  # nothing shown yet
    assert extract_search("search for basmati rice 1 kg", ctx) == {"query": "basmati rice 1 kg"}
    assert extract_search("atta dhundo", ctx) == {"query": "atta"}
    assert extract_search("hello", ctx) is None


async def test_compare_record_prices_staleness_and_checkout(
    shop: PluginRegistry, make_ctx: CtxFactory, owner: Owner, clock: FixedClock, fake_mcp: FakeMcpClient
) -> None:
    await search(shop, make_ctx)
    first = await done(
        shop, make_ctx(turn_id="t1"), "shopping.basket_add", {"reference": "second one", "quantity": 3}, "a1"
    )
    await done(
        shop,
        make_ctx(turn_id="t2"),
        "shopping.basket_add",
        {"reference": "first", "variant_hint": "10 kg"},
        "a2",
    )
    atta_id = first.result.item.item_id
    view = await done(shop, make_ctx(turn_id="t3"), "shopping.basket_view", {}, "v1")
    assert view.result.basket.known_total == Decimal("1344.00")
    assert view.summary == "Your basket has 2 items; 2 are priced, totalling ₹1,344.00."

    rec = await done(shop, make_ctx(turn_id="t4"), "shopping.record_price",
                     {"provider": "swiggy_instamart", "kind": "delivery_fee", "price": "30"}, "r1")  # fmt: skip
    assert rec.summary == "Recorded ₹30.00 at swiggy_instamart."
    await done(shop, make_ctx(turn_id="t5"), "shopping.record_price",
               {"provider": "blinkit", "item_id": atta_id, "price": "250.50"}, "r2")  # fmt: skip
    by_words = await done(shop, make_ctx(turn_id="t6"), "shopping.record_price",
                          {"provider": "blinkit", "reference": "the second item", "price": "500"}, "r3")  # fmt: skip
    assert by_words.result.status == "recorded"

    cmp_out = await done(shop, make_ctx(turn_id="t7"), "shopping.compare_basket", {}, "cmp1")
    rows = {r.provider: r for r in cmp_out.result.comparison.providers}
    assert rows["swiggy_instamart"].status == "ranked" and rows["swiggy_instamart"].final_payable == Decimal(
        "1374.00"
    )
    assert rows["blinkit"].status == "ranked" and rows["blinkit"].fees_known is False
    assert (
        rows["flipkart_affiliate"].status == "unavailable" and rows["flipkart_affiliate"].handoff is not None
    )
    assert cmp_out.result.comparison.cheapest_provider is None  # Blinkit's fees are unknown
    assert cmp_out.card is not None and cmp_out.card.kind == "basket_comparison"

    clock.advance(delta=timedelta(minutes=31))  # provider prices go stale, owner-entered ones do not
    stale = await done(shop, make_ctx(turn_id="t8"), "shopping.compare_basket", {}, "cmp2")
    rows = {r.provider: r for r in stale.result.comparison.providers}
    assert rows["swiggy_instamart"].status == "partial" and len(rows["swiggy_instamart"].stale_items) == 2
    clock.advance(delta=timedelta(minutes=-31))

    args = {"provider": "swiggy_instamart", "expected_payable": "1374.00", "location_ref": "addr_1"}
    denied = await run(shop, make_ctx(turn_id="t9"), "shopping.prepare_checkout", args, "co1")
    assert isinstance(denied, Denied) and denied.reason == "permission_not_granted:shopping.provider_cart"

    await shop.service("permissions").set("shopping.provider_cart", True)
    ctx = make_ctx(turn_id="t10")
    pending = await run(shop, ctx, "shopping.prepare_checkout", args, "co2")
    assert isinstance(pending, NeedsApproval) and pending.request.level is ApprovalLevel.CONFIRM
    assert pending.request.title == "Prepare your Swiggy Instamart cart"
    assert "₹1,374.00" in pending.request.summary and fake_mcp.calls[-1][0] == "search_products"
    executor: ToolExecutor = shop.service("tool_executor")
    finished = await executor.resume_with_approval(ctx, "co2", owner.signer.sign_approval(pending.request))
    assert isinstance(finished, Completed), finished
    result = finished.result
    assert result.status == "cart_prepared" and result.final_payable == Decimal("1374.00")
    assert result.provider_to_pay == Decimal("304.00") and result.warnings  # bill mismatch is surfaced
    name, sent = fake_mcp.calls[-1]
    assert name == "update_cart" and sent["selectedAddressId"] == "addr_1"
    assert sorted((i["spinId"], i["quantity"]) for i in sent["items"]) == [("spin_a10", 1), ("spin_p5", 3)]
    assert not any(n in ("checkout", "confirm_order", "get_payment_options") for n, _ in fake_mcp.calls)
    assert finished.summary == "Your swiggy_instamart cart is ready; pay in the swiggy_instamart app."


async def test_checkout_verification_rejects(shop: PluginRegistry, make_ctx: CtxFactory) -> None:
    svc = shop.service("shopping")
    await search(shop, make_ctx)
    await done(shop, make_ctx(turn_id="t1"), "shopping.basket_add", {"reference": "second one"}, "a1")
    changed = await svc.prepare_checkout(None, "swiggy_instamart", Decimal("1.00"), "addr_1")
    assert changed.reason == "payable_changed" and changed.final_payable == Decimal("265.00")
    assert {c.check: c.ok for c in changed.checks}["fees_known"] is False
    await done(shop, make_ctx(turn_id="t2"), "shopping.record_price",
               {"provider": "swiggy_instamart", "kind": "delivery_fee", "price": "0"}, "r1")  # fmt: skip
    wrong = await svc.prepare_checkout(None, "swiggy_instamart", Decimal("1.00"), "addr_1")
    assert (
        wrong.status == "rejected"
        and wrong.reason == "payable_changed"
        and wrong.final_payable == Decimal("265.00")
    )
    assert (
        await svc.prepare_checkout(None, "swiggy_instamart", Decimal("265.00"), None)
    ).reason == "address_required"
    assert (await svc.prepare_checkout(None, "nope", Decimal("1"), "a")).reason == "unknown_provider"
    blinkit = await svc.prepare_checkout(None, "blinkit", Decimal("265.00"), "addr_1")
    assert blinkit.status == "rejected" and blinkit.reason == "incomplete_coverage"


async def test_policy_still_applies(shop: PluginRegistry, make_ctx: CtxFactory) -> None:
    await search(shop, make_ctx)
    tainted = await run(
        shop, make_ctx(turn_id="t1", tainted=True), "shopping.basket_add", {"reference": "second one"}, "x1"
    )
    assert isinstance(tainted, NeedsApproval) and tainted.request.level is ApprovalLevel.CONFIRM
    wrong_agent = await run(
        shop, make_ctx(turn_id="t2", agent=AgentId.FITNESS), "shopping.basket_view", {}, "x2"
    )
    assert isinstance(wrong_agent, Denied) and wrong_agent.reason == "agent_not_allowed"
    empty = await done(shop, make_ctx(turn_id="t3", conversation_id="other"), "shopping.basket_add",
                       {"reference": "the second one"}, "x3")  # fmt: skip
    assert empty.result.status == "not_found"  # nothing was shown in that conversation
    none = await done(shop, make_ctx(turn_id="t4"), "shopping.basket_view", {}, "x4")
    assert none.result.basket is None and none.summary == "There is no basket yet."


async def test_shortlist_details_quantity_and_remove(shop: PluginRegistry, make_ctx: CtxFactory) -> None:
    await search(shop, make_ctx)
    short = await done(
        shop, make_ctx(turn_id="t1"), "shopping.shortlist_add", {"reference": "third one"}, "s1"
    )
    assert short.result.entry.name == "Amul Taaza Toned Milk" and short.result.entry.price == Decimal("29.00")
    assert short.result.entry.attributes["size"] == "500 ml"
    details = await done(
        shop, make_ctx(turn_id="t2"), "shopping.product_details", {"reference": "teesra wala"}, "d1"
    )
    assert details.result.status == "ok" and details.result.live.reason == "not_supported"
    added = await done(shop, make_ctx(turn_id="t3"), "shopping.basket_add", {"reference": "third one"}, "b1")
    await done(shop, make_ctx(turn_id="t4"), "shopping.basket_view", {}, "v1")  # remembers basket items
    qty = await done(
        shop,
        make_ctx(turn_id="t5"),
        "shopping.basket_set_quantity",
        {"reference": "pehla", "quantity": 4},
        "q1",
    )
    assert qty.result.item.item_id == added.result.item.item_id and qty.result.item.quantity == 4
    gone = await done(
        shop, make_ctx(turn_id="t6", lang="hinglish"), "shopping.basket_remove", {"reference": "isko"}, "rm1"
    )
    assert gone.result.status == "removed" and gone.result.basket.items == []
    assert gone.summary == "Amul Taaza Toned Milk basket se hata diya."
