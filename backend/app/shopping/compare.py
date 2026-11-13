"""Basket comparison: pure, deterministic, exact (integer paise inside, Decimal rupees out).

Rules:
- exact matches price the basket; substitutes are reported separately and never mixed in;
- a stale price (older than the staleness rule for its provenance) is excluded and flagged;
- fees are added only when known; coupons/memberships honour minimum order, percent/flat and cap;
- only providers with complete, fresh exact coverage are ranked; partial providers list what is
  missing and are never called cheapest; "cheapest" is named only when every ranked provider's fees
  are known and the lowest payable is unique;
- a provider that cannot be queried officially and has no prices is reported with its handoff.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal
from typing import Literal

from pydantic import AwareDatetime, Field

from app.core.money import from_paise, percent_of_paise, to_paise
from app.shopping.types import DiscountRule, Handoff, Provenance, SModel

FeeKind = Literal["delivery_fee", "handling_fee", "platform_fee", "small_cart_fee", "other_fee"]


class OfferIn(SModel):
    item_id: str
    match_kind: Literal["exact", "substitute"]
    confidence: float = 1.0
    reasons: list[str] = Field(default_factory=list)
    unit_price_paise: int = Field(ge=0)
    observed_at: AwareDatetime
    provenance: Provenance
    source: str
    in_stock: bool | None = None
    label: str = ""


class FeeRule(SModel):
    kind: FeeKind
    label: str = ""
    amount_paise: int = Field(ge=0)
    waived_at_or_above_paise: int | None = None  # e.g. free delivery above ₹199
    applies_below_paise: int | None = None  # e.g. small-cart fee below ₹99
    observed_at: AwareDatetime
    provenance: Provenance
    source: str


class ProviderInput(SModel):
    provider: str
    title: str
    queryable: bool
    status: str = ""
    handoff: Handoff | None = None
    offers: list[OfferIn] = Field(default_factory=list)
    fees: list[FeeRule] | None = None  # None: fees not known for this provider
    discounts: list[DiscountRule] = Field(default_factory=list)


class BasketLineIn(SModel):
    item_id: str
    name: str
    quantity: int = Field(ge=1)
    substitutions_allowed: bool = False


class LineOut(SModel):
    item_id: str
    name: str
    quantity: int
    unit_price: Decimal
    line_total: Decimal
    provenance: Provenance
    source: str
    observed_at: datetime
    confidence: float


class SubstituteOut(SModel):
    item_id: str
    name: str
    offer_label: str
    unit_price: Decimal
    line_total: Decimal
    confidence: float
    reasons: list[str]
    allowed: bool


class MissingOut(SModel):
    item_id: str
    name: str
    reason: Literal["no_offer", "stale_price", "out_of_stock"]


class FeeOut(SModel):
    kind: str
    label: str
    amount: Decimal
    waived: bool = False


class DiscountOut(SModel):
    code: str
    kind: str
    amount: Decimal


class ProviderResult(SModel):
    provider: str
    title: str
    status: Literal["ranked", "partial", "unavailable"]
    rank: int | None = None
    item_total: Decimal
    fees: list[FeeOut] = Field(default_factory=list)
    fees_known: bool = False
    fee_total: Decimal = Decimal("0.00")
    discounts: list[DiscountOut] = Field(default_factory=list)
    discount_total: Decimal = Decimal("0.00")
    final_payable: Decimal | None = None  # only for complete coverage
    exact_items: int = 0
    total_items: int = 0
    coverage_pct: int = 0
    match_confidence: float | None = None
    lines: list[LineOut] = Field(default_factory=list)
    substitutes: list[SubstituteOut] = Field(default_factory=list)
    missing: list[MissingOut] = Field(default_factory=list)
    stale_items: list[str] = Field(default_factory=list)
    handoff: Handoff | None = None
    notes: list[str] = Field(default_factory=list)


class ComparisonResult(SModel):
    computed_at: datetime
    total_items: int
    providers: list[ProviderResult]
    cheapest_provider: str | None = None
    cheapest_reason: str  # cheapest | fees_unknown | tie | no_complete_provider | empty_basket


def is_stale(
    observed_at: datetime, provenance: str, now: datetime, staleness_minutes: dict[str, int]
) -> bool:
    limit = staleness_minutes.get(provenance)
    return limit is None or now - observed_at > timedelta(minutes=limit)


def _fees(rules: list[FeeRule], item_total: int, free_delivery: bool) -> tuple[list[FeeOut], int]:
    out: list[FeeOut] = []
    total = 0
    for rule in rules:
        waived = (
            (rule.waived_at_or_above_paise is not None and item_total >= rule.waived_at_or_above_paise)
            or (rule.applies_below_paise is not None and item_total >= rule.applies_below_paise)
            or (free_delivery and rule.kind == "delivery_fee")
        )
        amount = 0 if waived else rule.amount_paise
        total += amount
        out.append(
            FeeOut(kind=rule.kind, label=rule.label or rule.kind, amount=from_paise(amount), waived=waived)
        )
    return out, total


def discount_amount(rule: DiscountRule, item_total: int) -> int:
    """Paise off for one rule (0 when the minimum order is not met)."""
    if item_total < rule.min_order_paise or rule.kind == "free_delivery":
        return 0
    amount = percent_of_paise(item_total, rule.value) if rule.kind == "percent" else to_paise(rule.value)
    if rule.cap_paise is not None:
        amount = min(amount, rule.cap_paise)
    return max(0, min(amount, item_total))


def _discounts(rules: list[DiscountRule], item_total: int) -> tuple[list[DiscountOut], int, bool]:
    applied: list[DiscountOut] = []
    free_delivery = False
    for rule in (r for r in rules if r.membership):
        if rule.kind == "free_delivery" and item_total >= rule.min_order_paise:
            free_delivery = True
            applied.append(DiscountOut(code=rule.code, kind=rule.kind, amount=Decimal("0.00")))
        elif (amount := discount_amount(rule, item_total)) > 0:
            applied.append(DiscountOut(code=rule.code, kind=rule.kind, amount=from_paise(amount)))
    coupons = [(discount_amount(r, item_total), r) for r in rules if not r.membership]
    best = max(coupons, key=lambda pair: (pair[0], pair[1].code), default=None)
    if best is not None and best[0] > 0:
        applied.append(DiscountOut(code=best[1].code, kind=best[1].kind, amount=from_paise(best[0])))
    total = sum(to_paise(d.amount) for d in applied)
    return applied, min(total, item_total), free_delivery


def compare_provider(
    items: list[BasketLineIn], p: ProviderInput, now: datetime, staleness_minutes: dict[str, int]
) -> ProviderResult:
    result = ProviderResult(
        provider=p.provider,
        title=p.title,
        status="partial",
        item_total=Decimal("0.00"),
        total_items=len(items),
        handoff=p.handoff,
    )
    if not p.offers and not p.queryable:
        result.status = "unavailable"
        result.notes.append("Cannot be queried through an official route; open the provider instead.")
        result.missing = [MissingOut(item_id=i.item_id, name=i.name, reason="no_offer") for i in items]
        return result
    item_total = 0
    confidences: list[float] = []
    for item in items:
        offers = [o for o in p.offers if o.item_id == item.item_id]
        exact = sorted(
            (o for o in offers if o.match_kind == "exact"), key=lambda o: o.observed_at, reverse=True
        )
        chosen = exact[0] if exact else None
        if chosen is None:
            result.missing.append(MissingOut(item_id=item.item_id, name=item.name, reason="no_offer"))
        elif is_stale(chosen.observed_at, chosen.provenance, now, staleness_minutes):
            result.missing.append(MissingOut(item_id=item.item_id, name=item.name, reason="stale_price"))
            result.stale_items.append(item.item_id)
        elif chosen.in_stock is False:
            result.missing.append(MissingOut(item_id=item.item_id, name=item.name, reason="out_of_stock"))
        else:
            line = chosen.unit_price_paise * item.quantity
            item_total += line
            confidences.append(chosen.confidence)
            result.lines.append(
                LineOut(
                    item_id=item.item_id,
                    name=item.name,
                    quantity=item.quantity,
                    unit_price=from_paise(chosen.unit_price_paise),
                    line_total=from_paise(line),
                    provenance=chosen.provenance,
                    source=chosen.source,
                    observed_at=chosen.observed_at,
                    confidence=chosen.confidence,
                )
            )
        for sub in (o for o in offers if o.match_kind == "substitute"):
            if is_stale(sub.observed_at, sub.provenance, now, staleness_minutes) or sub.in_stock is False:
                continue
            result.substitutes.append(
                SubstituteOut(
                    item_id=item.item_id,
                    name=item.name,
                    offer_label=sub.label,
                    unit_price=from_paise(sub.unit_price_paise),
                    line_total=from_paise(sub.unit_price_paise * item.quantity),
                    confidence=sub.confidence,
                    reasons=sub.reasons,
                    allowed=item.substitutions_allowed,
                )
            )
    result.item_total = from_paise(item_total)
    result.exact_items = len(result.lines)
    result.coverage_pct = (100 * result.exact_items) // len(items) if items else 0
    result.match_confidence = min(confidences) if confidences else None
    if result.missing:
        return result

    discounts, discount_total, free_delivery = _discounts(p.discounts, item_total)
    fees_known = p.fees is not None and all(
        not is_stale(f.observed_at, f.provenance, now, staleness_minutes) for f in p.fees
    )
    fees, fee_total = _fees(p.fees or [], item_total, free_delivery) if fees_known else ([], 0)
    if not fees_known:
        result.notes.append("Fees not known; the payable may be higher.")
    result.fees, result.fees_known, result.fee_total = fees, fees_known, from_paise(fee_total)
    result.discounts, result.discount_total = discounts, from_paise(discount_total)
    result.final_payable = from_paise(item_total + fee_total - discount_total)
    result.status = "ranked"
    return result


def compare_basket(
    items: list[BasketLineIn],
    providers: list[ProviderInput],
    now: datetime,
    staleness_minutes: dict[str, int],
) -> ComparisonResult:
    results = [compare_provider(items, p, now, staleness_minutes) for p in providers]
    ranked = sorted(
        (r for r in results if r.status == "ranked" and r.final_payable is not None),
        key=lambda r: (r.final_payable or Decimal(0), r.provider),
    )
    for position, r in enumerate(ranked, start=1):
        r.rank = position
    cheapest, reason = None, "no_complete_provider"
    if not items:
        reason = "empty_basket"
    elif ranked:
        if not all(r.fees_known for r in ranked):
            reason = "fees_unknown"
        elif len(ranked) > 1 and ranked[0].final_payable == ranked[1].final_payable:
            reason = "tie"
        else:
            cheapest, reason = ranked[0].provider, "cheapest"
    order = {"ranked": 0, "partial": 1, "unavailable": 2}
    results.sort(key=lambda r: (order[r.status], r.rank or 0, -r.coverage_pct, r.provider))
    return ComparisonResult(
        computed_at=now,
        total_items=len(items),
        providers=results,
        cheapest_provider=cheapest,
        cheapest_reason=reason,
    )
