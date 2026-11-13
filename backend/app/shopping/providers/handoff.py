"""Providers without an official route ZORO can use: they only open the provider's own page.

No scraping, no unofficial MCP servers. Search answers `Unavailable(reason="handoff_only")` with the
provider's search URL, so the owner can look there themselves.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import ClassVar

from app.core.types import CapabilityStatus, IntegrationLevel
from app.shopping.providers.base import ALL_METHODS, ShoppingProvider, handoff_levels
from app.shopping.types import ProviderMethod, SearchResults, Unavailable


class HandoffProvider(ShoppingProvider):
    """Zepto, Blinkit, BigBasket, Flipkart Minutes, Amazon Now, Amazon India, Flipkart web, Myntra."""

    levels: ClassVar[Mapping[ProviderMethod, IntegrationLevel]] = handoff_levels()

    async def status(self) -> CapabilityStatus:
        return CapabilityStatus.MANUAL_USER_STEP

    def status_note(self) -> str:
        return "No official API found; ZORO opens the provider's own page."

    async def search_products(
        self, query: str, *, location_ref: str | None = None, limit: int = 10
    ) -> SearchResults | Unavailable:
        return self.unavailable(
            ProviderMethod.SEARCH_PRODUCTS,
            "handoff_only",
            f"{self.config.title} has no official search API. Opening its own search instead.",
            query=query,
        )


class PartnershipProvider(ShoppingProvider):
    """Amazon Creators API: real, but gated by Associates eligibility. No endpoints are invented."""

    levels: ClassVar[Mapping[ProviderMethod, IntegrationLevel]] = {
        **dict.fromkeys(ALL_METHODS, IntegrationLevel.UNAVAILABLE),
        ProviderMethod.OPEN_PROVIDER_APP: IntegrationLevel.DEEP_LINK_HANDOFF,
    }

    async def status(self) -> CapabilityStatus:
        return CapabilityStatus.REQUIRES_PARTNERSHIP

    def status_note(self) -> str:
        return self.config.partnership_note

    async def search_products(
        self, query: str, *, location_ref: str | None = None, limit: int = 10
    ) -> SearchResults | Unavailable:
        return self.unavailable(
            ProviderMethod.SEARCH_PRODUCTS, "requires_partnership", self.config.partnership_note, query=query
        )
