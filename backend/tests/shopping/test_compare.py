from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from typing import Any

from app.shopping.compare import (
    BasketLineIn,
    FeeRule,
    OfferIn,
    ProviderInput,
    compare_basket,
    discount_amount,
)
from app.shopping.types import DiscountRule, Handoff

from .conftest import NOW

STALE = {"provider_api": 30, "user_reported": 1440, "user_screenshot_ocr": 720}
ITEMS = [
    BasketLineIn(item_id="atta", name="Atta 5 kg", quantity=1),
    BasketLineIn(item_id="milk", name="Milk 500 ml", quantity=3, substitutions_allowed=True),
]


def offer(
    item: str, paise: int, *, kind: str = "exact", age_min: int = 0, prov: str = "provider_api", **kw: Any
) -> OfferIn:
    return OfferIn(
        item_id=item, match_kind=kind, unit_price_paise=paise, observed_at=NOW - timedelta(minutes=age_min),
        provenance=prov, source=f"test:{prov}", **kw,
    )  # fmt: skip


def fee(kind: str, paise: int, **kw: Any) -> FeeRule:
    return FeeRule(
        kind=kind, amount_paise=paise, observed_at=NOW, provenance="provider_api", source="test", **kw
    )


def provider(pid: str, offers: list[OfferIn], fees: list[FeeRule] | None = None, **kw: Any) -> ProviderInput:
    return ProviderInput(provider=pid, title=pid.title(), queryable=True, offers=offers, fees=fees, **kw)


def test_basket_arithmetic_to_the_paisa() -> None:
    a = provider(
        "a",
        [offer("atta", 28933), offer("milk", 2917)],
        [fee("delivery_fee", 2500), fee("handling_fee", 999)],
    )
    result = compare_basket(ITEMS, [a], NOW, STALE)
    row = result.providers[0]
    assert row.status == "ranked" and row.rank == 1
    assert row.item_total == Decimal("376.84")  # 289.33 + 3 x 29.17
    assert row.fee_total == Decimal("34.99")
    assert row.final_payable == Decimal("411.83")
    assert [line.line_total for line in row.lines] == [Decimal("289.33"), Decimal("87.51")]
    assert row.coverage_pct == 100 and row.match_confidence == 1.0
    assert result.cheapest_provider == "a" and result.cheapest_reason == "cheapest"


def test_coupons_minimum_order_percent_flat_cap_and_membership() -> None:
    pct = DiscountRule(code="TEN", kind="percent", value=Decimal(10), cap_paise=3000, min_order_paise=20000)
    assert discount_amount(pct, 37684) == 3000  # 10% = 37.68, capped at 30
    assert discount_amount(pct, 19999) == 0  # minimum order not met
    assert (
        discount_amount(DiscountRule(code="F", kind="flat", value=Decimal("50")), 3000) == 3000
    )  # never below 0
    assert (
        discount_amount(DiscountRule(code="P", kind="percent", value=Decimal("7.5")), 10001) == 750
    )  # half-even

    flat = DiscountRule(code="FLAT40", kind="flat", value=Decimal(40), min_order_paise=30000)
    member = DiscountRule(code="ONE", kind="free_delivery", membership=True, min_order_paise=19900)
    a = provider(
        "a",
        [offer("atta", 28933), offer("milk", 2917)],
        [fee("delivery_fee", 2500)],
        discounts=[pct, flat, member],
    )
    row = compare_basket(ITEMS, [a], NOW, STALE).providers[0]
    assert [(d.code, d.amount) for d in row.discounts] == [
        ("ONE", Decimal("0.00")),
        ("FLAT40", Decimal("40.00")),
    ]
    assert row.fees[0].waived and row.fee_total == Decimal("0.00")  # membership free delivery
    assert row.final_payable == Decimal("336.84")


def test_fee_thresholds_free_delivery_and_small_cart() -> None:
    fees = [
        fee("delivery_fee", 3000, waived_at_or_above_paise=19900),
        fee("small_cart_fee", 1500, applies_below_paise=9900),
    ]
    small = compare_basket(ITEMS[:1], [provider("a", [offer("atta", 5000)], fees)], NOW, STALE).providers[0]
    assert small.fee_total == Decimal("45.00") and small.final_payable == Decimal("95.00")
    big = compare_basket(ITEMS[:1], [provider("a", [offer("atta", 28900)], fees)], NOW, STALE).providers[0]
    assert big.fee_total == Decimal("0.00") and all(f.waived for f in big.fees)


def test_missing_products_and_substitutes_are_reported_separately() -> None:
    b = provider(
        "b",
        [
            offer(
                "atta",
                26500,
                kind="substitute",
                confidence=0.6,
                reasons=["different brand"],
                label="Pillsbury 5 kg",
            )
        ],
    )
    row = compare_basket(ITEMS, [b], NOW, STALE).providers[0]
    assert row.status == "partial" and row.final_payable is None and row.rank is None
    assert {m.item_id: m.reason for m in row.missing} == {"atta": "no_offer", "milk": "no_offer"}
    assert row.item_total == Decimal("0.00")  # substitutes never enter exact totals
    assert row.substitutes[0].offer_label == "Pillsbury 5 kg" and row.substitutes[0].allowed is False


def test_stale_prices_are_excluded_and_flagged() -> None:
    a = provider("a", [offer("atta", 28900, age_min=31), offer("milk", 2900)], [])
    user = provider(
        "u",
        [offer("atta", 27000, prov="user_reported", age_min=600), offer("milk", 2800, prov="user_reported")],
        [],
    )
    result = compare_basket(ITEMS, [a, user], NOW, STALE)
    rows = {r.provider: r for r in result.providers}
    assert rows["a"].status == "partial" and rows["a"].stale_items == ["atta"]
    assert rows["a"].missing[0].reason == "stale_price"
    assert rows["u"].status == "ranked"  # user prices stay usable for a day
    assert result.cheapest_provider == "u"
    stale_fee = provider(
        "f",
        [offer("atta", 1), offer("milk", 1)],
        [fee("delivery_fee", 100).model_copy(update={"observed_at": NOW - timedelta(hours=2)})],
    )
    assert compare_basket(ITEMS, [stale_fee], NOW, STALE).providers[0].fees_known is False


def test_partial_coverage_is_never_ranked_cheapest() -> None:
    cheap_partial = provider("cheap", [offer("atta", 100)], [])
    full = provider("full", [offer("atta", 28900), offer("milk", 2900)], [])
    result = compare_basket(ITEMS, [cheap_partial, full], NOW, STALE)
    assert result.cheapest_provider == "full"
    rows = {r.provider: r for r in result.providers}
    assert (
        rows["cheap"].status == "partial" and rows["cheap"].rank is None and rows["cheap"].coverage_pct == 50
    )
    only_partial = compare_basket(ITEMS, [cheap_partial], NOW, STALE)
    assert only_partial.cheapest_provider is None and only_partial.cheapest_reason == "no_complete_provider"


def test_out_of_stock_unknown_fees_and_ties_name_no_cheapest() -> None:
    oos = provider("o", [offer("atta", 1, in_stock=False), offer("milk", 1)], [])
    assert compare_basket(ITEMS, [oos], NOW, STALE).providers[0].missing[0].reason == "out_of_stock"

    known = provider("k", [offer("atta", 28900), offer("milk", 2900)], [])
    unknown = provider("n", [offer("atta", 20000), offer("milk", 2000)], None)
    result = compare_basket(ITEMS, [known, unknown], NOW, STALE)
    assert result.cheapest_provider is None and result.cheapest_reason == "fees_unknown"
    assert [r.provider for r in result.providers if r.status == "ranked"] == ["n", "k"]

    twin = provider("t", [offer("atta", 28900), offer("milk", 2900)], [])
    assert compare_basket(ITEMS, [known, twin], NOW, STALE).cheapest_reason == "tie"
    assert compare_basket([], [known], NOW, STALE).cheapest_reason == "empty_basket"


def test_unavailable_provider_is_reported_with_its_handoff() -> None:
    handoff = Handoff(
        provider="blinkit", title="Blinkit", url="https://blinkit.example.test/", verified=False
    )
    blinkit = ProviderInput(provider="blinkit", title="Blinkit", queryable=False, handoff=handoff)
    row = compare_basket(ITEMS, [blinkit], NOW, STALE).providers[0]
    assert row.status == "unavailable" and row.handoff == handoff and row.final_payable is None
    assert len(row.missing) == 2
