"""`ShoppingProvider`: one interface for every retailer, with an honest integration level per method.

A subclass overrides only what its official route supports and declares that in `levels`. Every
other method answers `Unavailable` with the provider's handoff, so callers never receive a guess.
"""

from __future__ import annotations

from abc import ABC
from collections.abc import Mapping
from datetime import datetime
from typing import ClassVar

from app.core.clock import Clock, SystemClock
from app.core.types import CapabilityStatus, IntegrationLevel
from app.shopping.config import ProviderConfig
from app.shopping.types import (
    Availability,
    CartLine,
    CheckoutHandoff,
    DeliveryEstimate,
    DiscountList,
    FeeSchedule,
    Handoff,
    MethodLevel,
    PriceQuote,
    Product,
    ProviderCart,
    ProviderInfo,
    ProviderMethod,
    SearchResults,
    Unavailable,
)

ALL_METHODS: tuple[ProviderMethod, ...] = tuple(ProviderMethod)


class ShoppingProvider(ABC):
    """Base class. `levels` must name every `ProviderMethod` (checked by `validate_levels`)."""

    id: str
    levels: ClassVar[Mapping[ProviderMethod, IntegrationLevel]]

    def __init__(self, provider_id: str, config: ProviderConfig, *, clock: Clock | None = None) -> None:
        self.id = provider_id
        self.config = config
        self.clock = clock or SystemClock()

    # ---------------------------------------------------------------- status and helpers

    async def status(self) -> CapabilityStatus:
        return CapabilityStatus.MANUAL_USER_STEP

    def status_note(self) -> str:
        return ""

    def now(self) -> datetime:
        return self.clock.now()

    def handoff(self, query: str | None = None) -> Handoff | None:
        url = self.config.handoff.render(query)
        if url is None:
            return None
        note = "" if self.config.handoff.verified else "Link format not confirmed in official docs."
        return Handoff(
            provider=self.id,
            title=self.config.title,
            url=url,
            verified=self.config.handoff.verified,
            note=note,
        )

    def unavailable(
        self,
        method: ProviderMethod,
        reason: str = "not_supported",
        message: str = "",
        query: str | None = None,
    ) -> Unavailable:
        return Unavailable(
            provider=self.id, method=method, reason=reason, message=message, handoff=self.handoff(query)
        )

    def level(self, method: ProviderMethod) -> IntegrationLevel:
        return self.levels.get(method, IntegrationLevel.UNAVAILABLE)

    async def info(self) -> ProviderInfo:
        status = await self.status()
        return ProviderInfo(
            id=self.id,
            title=self.config.title,
            category=self.config.category,
            status=status.value,
            methods=[MethodLevel(method=m, level=self.level(m)) for m in ALL_METHODS],
            handoff=self.handoff(),
            note=self.status_note(),
        )

    # ---------------------------------------------------------------- the contract

    async def search_products(
        self, query: str, *, location_ref: str | None = None, limit: int = 10
    ) -> SearchResults | Unavailable:
        return self.unavailable(ProviderMethod.SEARCH_PRODUCTS, query=query)

    async def get_product_details(self, product_id: str) -> Product | Unavailable:
        return self.unavailable(ProviderMethod.GET_PRODUCT_DETAILS)

    async def get_availability(
        self, product_id: str, variant_id: str | None = None, *, location_ref: str | None = None
    ) -> Availability | Unavailable:
        return self.unavailable(ProviderMethod.GET_AVAILABILITY)

    async def get_current_price(
        self, product_id: str, variant_id: str | None = None, *, location_ref: str | None = None
    ) -> PriceQuote | Unavailable:
        return self.unavailable(ProviderMethod.GET_CURRENT_PRICE)

    async def get_variants(self, product_id: str) -> Product | Unavailable:
        return self.unavailable(ProviderMethod.GET_VARIANTS)

    async def get_delivery_estimate(
        self, *, location_ref: str | None = None
    ) -> DeliveryEstimate | Unavailable:
        return self.unavailable(ProviderMethod.GET_DELIVERY_ESTIMATE)

    async def get_delivery_fee(self, *, location_ref: str | None = None) -> FeeSchedule | Unavailable:
        return self.unavailable(ProviderMethod.GET_DELIVERY_FEE)

    async def get_applicable_discounts(
        self, *, location_ref: str | None = None
    ) -> DiscountList | Unavailable:
        return self.unavailable(ProviderMethod.GET_APPLICABLE_DISCOUNTS)

    async def add_to_cart(
        self, lines: list[CartLine], *, location_ref: str | None = None
    ) -> ProviderCart | Unavailable:
        return self.unavailable(ProviderMethod.ADD_TO_CART)

    async def get_cart(self) -> ProviderCart | Unavailable:
        return self.unavailable(ProviderMethod.GET_CART)

    async def prepare_checkout(
        self, lines: list[CartLine], *, location_ref: str | None = None
    ) -> CheckoutHandoff | Unavailable:
        return self.unavailable(ProviderMethod.PREPARE_CHECKOUT)

    async def open_provider_app(self, query: str | None = None) -> Handoff | Unavailable:
        handoff = self.handoff(query)
        if handoff is None:
            return self.unavailable(ProviderMethod.OPEN_PROVIDER_APP, "no_handoff_configured")
        return handoff

    async def aclose(self) -> None:
        return None


def validate_levels(provider: ShoppingProvider) -> list[ProviderMethod]:
    """Methods the provider forgot to declare (must be empty)."""
    return [m for m in ALL_METHODS if m not in provider.levels]


def handoff_levels(
    open_level: IntegrationLevel = IntegrationLevel.DEEP_LINK_HANDOFF,
) -> dict[ProviderMethod, IntegrationLevel]:
    """Everything unavailable except opening the provider's page."""
    levels = dict.fromkeys(ALL_METHODS, IntegrationLevel.UNAVAILABLE)
    levels[ProviderMethod.OPEN_PROVIDER_APP] = open_level
    levels[ProviderMethod.SEARCH_PRODUCTS] = IntegrationLevel.DEEP_LINK_HANDOFF
    return levels
