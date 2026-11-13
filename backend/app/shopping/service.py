"""`ShoppingService`: the façade tools and routes use (service name ``shopping``)."""

from __future__ import annotations

from decimal import Decimal
from typing import Literal

from pydantic import Field

from app.core.clock import Clock
from app.core.money import to_paise
from app.core.types import CapabilityStatus
from app.shopping.basket import BasketService, BasketView
from app.shopping.compare import ComparisonResult, ProviderInput, compare_basket
from app.shopping.config import ShoppingConfig
from app.shopping.providers.hub import ProviderHub
from app.shopping.shortlist import ShortlistService
from app.shopping.types import (
    CartLine,
    DiscountRule,
    Handoff,
    ProviderMethod,
    SearchResults,
    SModel,
    Unavailable,
)

_CART_LEVELS = ("official_api", "fully_integrated")


class SearchOutcome(SModel):
    query: str
    results: list[SearchResults] = Field(default_factory=list)
    unavailable: list[Unavailable] = Field(default_factory=list)


class CheckoutCheck(SModel):
    check: str
    ok: bool
    detail: str = ""


class CheckoutResult(SModel):
    status: Literal["cart_prepared", "handoff", "rejected"]
    provider: str
    reason: str = ""
    checks: list[CheckoutCheck] = Field(default_factory=list)
    final_payable: Decimal | None = None
    provider_to_pay: Decimal | None = None
    handoff: Handoff | None = None
    warnings: list[str] = Field(default_factory=list)
    note: str = "Payment happens only in the provider's own app."


class ShoppingService:
    def __init__(
        self,
        config: ShoppingConfig,
        hub: ProviderHub,
        baskets: BasketService,
        shortlist: ShortlistService,
        clock: Clock,
    ) -> None:
        self.config = config
        self.hub = hub
        self.baskets = baskets
        self.shortlist = shortlist
        self.clock = clock

    async def search(
        self,
        query: str,
        *,
        providers: list[str] | None = None,
        location_ref: str | None = None,
        limit: int = 5,
    ) -> SearchOutcome:
        outcome = SearchOutcome(query=query)
        for provider in self.hub.all():
            if providers and provider.id not in providers:
                continue
            answer = await provider.search_products(query, location_ref=location_ref, limit=limit)
            if isinstance(answer, Unavailable):
                outcome.unavailable.append(answer)
            else:
                outcome.results.append(answer)
        return outcome

    async def compare(
        self, basket_id: str | None, discounts: dict[str, list[DiscountRule]] | None = None
    ) -> tuple[BasketView, ComparisonResult]:
        view, lines, offers, fees = await self.baskets.compare_inputs(basket_id)
        statuses = await self.hub.refresh_status()
        inputs: list[ProviderInput] = []
        for provider in self.hub.all():
            inputs.append(
                ProviderInput(
                    provider=provider.id,
                    title=provider.config.title,
                    queryable=statuses[provider.id] is CapabilityStatus.WORKING_INTEGRATION,
                    status=statuses[provider.id].value,
                    handoff=provider.handoff(),
                    offers=offers.get(provider.id, []),
                    fees=fees.get(provider.id),
                    discounts=(discounts or {}).get(provider.id, []),
                )
            )
        result = compare_basket(lines, inputs, self.clock.now(), dict(self.config.staleness_minutes))
        return view, result

    async def prepare_checkout(
        self, basket_id: str | None, provider_id: str, expected_payable: Decimal, location_ref: str | None
    ) -> CheckoutResult:
        checks: list[CheckoutCheck] = []

        def reject(reason: str) -> CheckoutResult:
            return CheckoutResult(status="rejected", provider=provider_id, reason=reason, checks=checks)

        provider = self.hub.get(provider_id)
        checks.append(CheckoutCheck(check="provider", ok=provider is not None, detail=provider_id))
        if provider is None:
            return reject("unknown_provider")
        view, comparison = await self.compare(basket_id)
        quantities_ok = bool(view.items) and all(1 <= i.quantity <= 99 for i in view.items)
        checks.append(CheckoutCheck(check="quantities", ok=quantities_ok, detail=f"{len(view.items)} items"))
        if not quantities_ok:
            return reject("empty_basket" if not view.items else "invalid_quantity")
        address = location_ref or view.customer_location_reference
        checks.append(CheckoutCheck(check="address_reference", ok=bool(address)))
        if not address:
            return reject("address_required")
        row = next(r for r in comparison.providers if r.provider == provider_id)
        complete = row.status == "ranked" and row.final_payable is not None
        checks.append(CheckoutCheck(check="exact_fresh_coverage", ok=complete, detail=f"{row.coverage_pct}%"))
        if not complete:
            return reject("incomplete_coverage")
        same = row.final_payable == expected_payable.quantize(Decimal("0.01"))
        checks.append(CheckoutCheck(check="final_payable", ok=same, detail=str(row.final_payable)))
        checks.append(CheckoutCheck(check="fees_known", ok=row.fees_known))
        if not same:
            result = reject("payable_changed")
            result.final_payable = row.final_payable
            return result

        if provider.level(ProviderMethod.PREPARE_CHECKOUT).value not in _CART_LEVELS:
            handoff = await provider.open_provider_app(view.items[0].name if len(view.items) == 1 else None)
            return CheckoutResult(
                status="handoff",
                provider=provider_id,
                checks=checks,
                warnings=[] if row.fees_known else ["Fees were not known; the provider's bill decides."],
                final_payable=row.final_payable,
                handoff=handoff if isinstance(handoff, Handoff) else None,
            )
        lines: list[CartLine] = []
        for item in view.items:
            retailer = next((r for r in item.available_retailers if r.get("provider") == provider_id), None)
            if retailer is None or not retailer.get("variant_id"):
                return reject("provider_item_unknown")
            sku = (
                (item.selected_variant or {}).get("sku_id")
                if (item.selected_variant or {}).get("provider") == provider_id
                else None
            )
            lines.append(
                CartLine(
                    product_id=retailer.get("product_id") or "",
                    variant_id=retailer["variant_id"],
                    sku_id=sku,
                    quantity=item.quantity,
                )
            )
        prepared = await provider.prepare_checkout(lines, location_ref=address)
        if isinstance(prepared, Unavailable):
            result = reject(prepared.reason)
            result.handoff = prepared.handoff
            return result
        warnings: list[str] = [] if row.fees_known else ["Fees were not known; the provider's bill decides."]
        to_pay = None if prepared.to_pay_paise is None else Decimal(prepared.to_pay_paise) / 100
        if to_pay is not None and to_paise(to_pay) != to_paise(row.final_payable or 0):
            warnings.append(
                f"The provider's bill says {to_pay:.2f}; check it in the provider's app before paying."
            )
        return CheckoutResult(
            status="cart_prepared",
            provider=provider_id,
            checks=checks,
            final_payable=row.final_payable,
            provider_to_pay=None if to_pay is None else to_pay.quantize(Decimal("0.01")),
            handoff=prepared.handoff,
            warnings=warnings,
        )
