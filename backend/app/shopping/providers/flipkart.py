"""Flipkart Affiliate API adapter (official, registered affiliates only).

Endpoint shape from https://affiliate.flipkart.com/api-docs/af_prod_ref.html (fetched 2026-11-13):
``GET {base}/1.0/search.json?query=…&resultCount=…`` (at most 10) and ``GET {base}/1.0/product.json?id=…``
with headers ``Fk-Affiliate-Id`` / ``Fk-Affiliate-Token``. Responses: ``productInfoList[]`` of objects
holding ``productBaseInfoV1``. The API's current health was not checked with a real token.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Mapping
from typing import Any, ClassVar

import httpx

from app.core.clock import Clock
from app.core.types import CapabilityStatus, IntegrationLevel
from app.shopping.config import ProviderConfig
from app.shopping.normalize import parse_pack, rupees_to_paise
from app.shopping.providers.base import ALL_METHODS, ShoppingProvider
from app.shopping.types import (
    Availability,
    PriceQuote,
    Product,
    ProviderMethod,
    SearchResults,
    Unavailable,
    Variant,
    stamp,
)

log = logging.getLogger(__name__)

ID_ENV = "FLIPKART_AFFILIATE_ID"
TOKEN_ENV = "FLIPKART_AFFILIATE_TOKEN"  # noqa: S105 - environment variable name, not a secret
_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
_MAX_RESULTS = 10


def _amount(block: Any) -> int | None:
    return rupees_to_paise(block.get("amount")) if isinstance(block, Mapping) else None


def parse_product(info: Mapping[str, Any], provider: str, method: ProviderMethod, at: Any) -> Product | None:
    base = info.get("productBaseInfoV1", info)
    if not isinstance(base, Mapping) or not base.get("productId") or not base.get("title"):
        return None
    special, selling = _amount(base.get("flipkartSpecialPrice")), _amount(base.get("flipkartSellingPrice"))
    attributes = {
        str(k): str(v) for k, v in (base.get("attributes") or {}).items() if v not in (None, "", [])
    }
    size = attributes.get("size")
    in_stock = base.get("inStock")
    variant = Variant(
        variant_id=str(base["productId"]),
        label=size or "",
        pack=parse_pack(size) or parse_pack(str(base["title"])),
        price_paise=special if special is not None else selling,
        mrp_paise=_amount(base.get("maximumRetailPrice")),
        in_stock=in_stock if isinstance(in_stock, bool) else None,
    )
    return Product(
        **stamp(provider, method, at),
        provider=provider,
        product_id=str(base["productId"]),
        name=str(base["title"]),
        brand=str(base["productBrand"]) if base.get("productBrand") else None,
        url=str(base["productUrl"]) if base.get("productUrl") else None,
        variants=[variant],
        attributes=attributes,
    )


class FlipkartAffiliateProvider(ShoppingProvider):
    levels: ClassVar[Mapping[ProviderMethod, IntegrationLevel]] = {
        **dict.fromkeys(ALL_METHODS, IntegrationLevel.UNAVAILABLE),
        ProviderMethod.SEARCH_PRODUCTS: IntegrationLevel.AFFILIATE_SEARCH,
        ProviderMethod.GET_PRODUCT_DETAILS: IntegrationLevel.AFFILIATE_SEARCH,
        ProviderMethod.GET_AVAILABILITY: IntegrationLevel.AFFILIATE_SEARCH,
        ProviderMethod.GET_CURRENT_PRICE: IntegrationLevel.AFFILIATE_SEARCH,
        ProviderMethod.GET_VARIANTS: IntegrationLevel.AFFILIATE_SEARCH,
        ProviderMethod.OPEN_PROVIDER_APP: IntegrationLevel.DEEP_LINK_HANDOFF,
    }

    def __init__(
        self,
        provider_id: str,
        config: ProviderConfig,
        *,
        clock: Clock | None = None,
        env: Mapping[str, str] | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__(provider_id, config, clock=clock)
        source = os.environ if env is None else env
        self._id = source.get(ID_ENV) or None
        self._token = source.get(TOKEN_ENV) or None
        self._transport = transport

    @property
    def configured(self) -> bool:
        return bool(self._id and self._token and self.config.base_url)

    async def status(self) -> CapabilityStatus:
        return (
            CapabilityStatus.WORKING_INTEGRATION if self.configured else CapabilityStatus.REQUIRES_CREDENTIALS
        )

    def status_note(self) -> str:
        if not self.configured:
            return f"Set {ID_ENV} and {TOKEN_ENV} (Flipkart affiliate account) to enable search."
        return "Credentials present; API reachability is not checked."

    async def _get(self, method: ProviderMethod, path: str, params: dict[str, str]) -> Any | Unavailable:
        if not self.configured:
            return self.unavailable(
                method, "requires_credentials", self.status_note(), query=params.get("query")
            )
        headers = {"Fk-Affiliate-Id": self._id or "", "Fk-Affiliate-Token": self._token or ""}
        try:
            async with httpx.AsyncClient(timeout=_TIMEOUT, transport=self._transport) as http:
                response = await http.get(f"{self.config.base_url}{path}", params=params, headers=headers)
        except httpx.HTTPError as exc:
            log.warning("flipkart request failed", extra={"error_type": type(exc).__name__})
            return self.unavailable(method, "provider_unreachable", query=params.get("query"))
        if response.status_code in (401, 403):
            return self.unavailable(method, "credentials_rejected", query=params.get("query"))
        if response.status_code != 200:
            return self.unavailable(
                method, f"provider_error_{response.status_code}", query=params.get("query")
            )
        try:
            return response.json()
        except ValueError:
            return self.unavailable(method, "malformed_response", query=params.get("query"))

    async def search_products(
        self, query: str, *, location_ref: str | None = None, limit: int = 10
    ) -> SearchResults | Unavailable:
        method = ProviderMethod.SEARCH_PRODUCTS
        params = {"query": query, "resultCount": str(max(1, min(limit, _MAX_RESULTS)))}
        body = await self._get(method, "/1.0/search.json", params)
        if isinstance(body, Unavailable):
            return body
        items = body.get("productInfoList") if isinstance(body, Mapping) else None
        if not isinstance(items, list):
            return self.unavailable(method, "malformed_response", query=query)
        at = self.now()
        products = [
            p for p in (parse_product(i, self.id, method, at) for i in items if isinstance(i, Mapping)) if p
        ]
        return SearchResults(**stamp(self.id, method, at), provider=self.id, query=query, products=products)

    async def get_product_details(self, product_id: str) -> Product | Unavailable:
        method = ProviderMethod.GET_PRODUCT_DETAILS
        body = await self._get(method, "/1.0/product.json", {"id": product_id})
        if isinstance(body, Unavailable):
            return body
        product = parse_product(body, self.id, method, self.now()) if isinstance(body, Mapping) else None
        return product or self.unavailable(method, "malformed_response")

    async def get_variants(self, product_id: str) -> Product | Unavailable:
        return await self.get_product_details(product_id)

    async def get_current_price(
        self, product_id: str, variant_id: str | None = None, *, location_ref: str | None = None
    ) -> PriceQuote | Unavailable:
        product = await self.get_product_details(product_id)
        if isinstance(product, Unavailable):
            return product.model_copy(update={"method": ProviderMethod.GET_CURRENT_PRICE})
        variant = product.variants[0]
        if variant.price_paise is None:
            return self.unavailable(ProviderMethod.GET_CURRENT_PRICE, "price_not_provided")
        return PriceQuote(
            source=product.source,
            retrieved_at=product.retrieved_at,
            provider=self.id,
            product_id=product_id,
            variant_id=variant.variant_id,
            price_paise=variant.price_paise,
            mrp_paise=variant.mrp_paise,
        )

    async def get_availability(
        self, product_id: str, variant_id: str | None = None, *, location_ref: str | None = None
    ) -> Availability | Unavailable:
        product = await self.get_product_details(product_id)
        if isinstance(product, Unavailable):
            return product.model_copy(update={"method": ProviderMethod.GET_AVAILABILITY})
        in_stock = product.variants[0].in_stock
        if in_stock is None:
            return self.unavailable(ProviderMethod.GET_AVAILABILITY, "stock_not_provided")
        return Availability(
            source=product.source,
            retrieved_at=product.retrieved_at,
            provider=self.id,
            product_id=product_id,
            variant_id=product_id,
            in_stock=in_stock,
        )
