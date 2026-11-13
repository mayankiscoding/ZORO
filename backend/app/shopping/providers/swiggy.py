"""Swiggy Instamart through its official MCP server (https://mcp.swiggy.com/im).

Tool names and result shapes are from the official reference
(https://mcp.swiggy.com/builders/docs/reference/instamart/, fetched 2026-11-13): `search_products`
(query, addressId | latitude+longitude, offset) -> data.products[].variations[] with spinId, skuId,
quantityDescription, price.mrp / price.offerPrice, isInStockAndAvailable; `update_cart`
(selectedAddressId, items[{spinId, skuId, quantity}]) replaces the whole cart; `get_cart` -> data with
items[] and billBreakdown {lineItems[{label, value}], toPay{label, value}}. Bill label texts are not
documented, so fees are classified from labels and every line is also kept verbatim.

ZORO never calls `checkout`, `confirm_order` or the payment tools: payment finishes in Swiggy's app.
MCP results are untrusted data: strings are cleaned and length-capped before use.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any, ClassVar, Literal, Protocol

from app.core.clock import Clock
from app.core.types import CapabilityStatus, IntegrationLevel
from app.shopping.config import ProviderConfig
from app.shopping.normalize import parse_pack, rupees_to_paise
from app.shopping.providers.base import ALL_METHODS, ShoppingProvider
from app.shopping.types import (
    CartLine,
    CheckoutHandoff,
    FeeLine,
    FeeSchedule,
    Product,
    ProviderCart,
    ProviderMethod,
    SearchResults,
    Unavailable,
    Variant,
    stamp,
)

log = logging.getLogger(__name__)

REQUIRED_OPERATIONS = ("search_products", "get_cart", "update_cart")
_CONTROL = re.compile(r"[\x00-\x1f\x7f<>]")


def clean(value: Any, limit: int = 200) -> str:
    """Untrusted text from the provider: no control characters or angle brackets, length-capped."""
    return _CONTROL.sub(" ", str(value)).strip()[:limit]


@dataclass(frozen=True)
class McpToolInfo:
    name: str
    description: str = ""


@dataclass(frozen=True)
class McpCallResult:
    structured: Mapping[str, Any] | None = None
    text: str = ""
    is_error: bool = False


class McpToolClient(Protocol):
    """The small surface ZORO needs from an MCP connection (fake in tests, mcp SDK in production)."""

    async def has_credentials(self) -> bool: ...
    async def list_tools(self) -> list[McpToolInfo]: ...
    async def call_tool(self, name: str, arguments: dict[str, Any]) -> McpCallResult: ...


class McpAuthRequired(Exception):
    """The MCP server needs the owner to connect (or reconnect) their account."""


@dataclass
class MappingReport:
    ok: bool
    missing: list[str] = field(default_factory=list)  # mapped tool names the server does not list
    unmapped_operations: list[str] = field(default_factory=list)


def validate_tool_map(config: ProviderConfig, listed: list[McpToolInfo]) -> MappingReport:
    names = {tool.name for tool in listed}
    unmapped = [op for op in REQUIRED_OPERATIONS if op not in config.tool_map]
    missing = sorted({tool for tool in config.tool_map.values() if tool not in names})
    return MappingReport(ok=not missing and not unmapped, missing=missing, unmapped_operations=unmapped)


_FEE_KINDS: tuple[
    tuple[str, Literal["delivery_fee", "handling_fee", "platform_fee", "small_cart_fee"]], ...
] = (
    ("small cart", "small_cart_fee"),
    ("delivery", "delivery_fee"),
    ("handling", "handling_fee"),
    ("platform", "platform_fee"),
)


def _payload(result: McpCallResult) -> Mapping[str, Any] | None:
    body: Any = result.structured
    if body is None and result.text:
        try:
            body = json.loads(result.text)
        except ValueError:
            return None
    if not isinstance(body, Mapping) or body.get("success") is False:
        return None
    data = body.get("data")
    return data if isinstance(data, Mapping) else None


class SwiggyInstamartProvider(ShoppingProvider):
    levels: ClassVar[Mapping[ProviderMethod, IntegrationLevel]] = {
        **dict.fromkeys(ALL_METHODS, IntegrationLevel.UNAVAILABLE),
        ProviderMethod.SEARCH_PRODUCTS: IntegrationLevel.OFFICIAL_API,
        ProviderMethod.GET_DELIVERY_FEE: IntegrationLevel.OFFICIAL_API,  # from the current cart's bill
        ProviderMethod.ADD_TO_CART: IntegrationLevel.OFFICIAL_API,
        ProviderMethod.GET_CART: IntegrationLevel.OFFICIAL_API,
        ProviderMethod.PREPARE_CHECKOUT: IntegrationLevel.OFFICIAL_API,  # cart only; payment in Swiggy's app
        ProviderMethod.OPEN_PROVIDER_APP: IntegrationLevel.DEEP_LINK_HANDOFF,
    }

    def __init__(
        self, provider_id: str, config: ProviderConfig, client: McpToolClient, *, clock: Clock | None = None
    ) -> None:
        super().__init__(provider_id, config, clock=clock)
        forbidden = set(config.forbidden_tools) & set(config.tool_map.values())
        if forbidden:
            raise ValueError(f"tool_map must not use order or payment tools: {sorted(forbidden)}")
        self._client = client
        self._report: MappingReport | None = None

    # ---------------------------------------------------------------- connection

    async def connect(self) -> MappingReport:
        """List the server's tools and check the configured mapping against them."""
        self._report = validate_tool_map(self.config, await self._client.list_tools())
        if not self._report.ok:
            log.warning("swiggy tool mapping mismatch", extra={"missing": self._report.missing})
        return self._report

    async def status(self) -> CapabilityStatus:
        if not await self._client.has_credentials():
            return CapabilityStatus.REQUIRES_CREDENTIALS
        if self._report is not None and not self._report.ok:
            return CapabilityStatus.UNAVAILABLE
        return CapabilityStatus.WORKING_INTEGRATION

    def status_note(self) -> str:
        if self._report is not None and not self._report.ok:
            return f"Swiggy's tool list no longer matches: missing {', '.join(self._report.missing)}."
        return "Connect your Swiggy account (OAuth) to search Instamart and prepare carts."

    async def _call(
        self, method: ProviderMethod, operation: str, arguments: dict[str, Any], query: str | None = None
    ) -> Mapping[str, Any] | Unavailable:
        if not await self._client.has_credentials():
            return self.unavailable(method, "requires_credentials", self.status_note(), query=query)
        try:
            report = self._report or await self.connect()
            if not report.ok:
                return self.unavailable(method, "tool_mapping_mismatch", self.status_note(), query=query)
            result = await self._client.call_tool(self.config.tool_map[operation], arguments)
        except McpAuthRequired:
            return self.unavailable(
                method, "requires_credentials", "Reconnect your Swiggy account.", query=query
            )
        except Exception as exc:
            log.warning("swiggy mcp call failed", extra={"error_type": type(exc).__name__})
            return self.unavailable(method, "provider_unreachable", query=query)
        data = _payload(result)
        if result.is_error or data is None:
            return self.unavailable(method, "provider_error", query=query)
        return data

    # ---------------------------------------------------------------- parsing

    def _product(self, raw: Mapping[str, Any], at: Any) -> Product | None:
        if not raw.get("productId") or not raw.get("displayName"):
            return None
        variants: list[Variant] = []
        attributes: dict[str, str] = {}
        for var in raw.get("variations") or []:
            if not isinstance(var, Mapping) or not var.get("spinId"):
                continue
            raw_price = var.get("price")
            price: Mapping[str, Any] = raw_price if isinstance(raw_price, Mapping) else {}
            label = clean(var.get("quantityDescription") or "", 60)
            stock = var.get("isInStockAndAvailable")
            max_q = var.get("maxQuantity")
            variants.append(
                Variant(
                    variant_id=clean(var["spinId"], 80),
                    sku_id=clean(var["skuId"], 80) if var.get("skuId") else None,
                    label=label,
                    pack=parse_pack(label),
                    price_paise=rupees_to_paise(price.get("offerPrice")),
                    mrp_paise=rupees_to_paise(price.get("mrp")),
                    in_stock=stock if isinstance(stock, bool) else None,
                    max_quantity=max_q if isinstance(max_q, int) and not isinstance(max_q, bool) else None,
                )
            )
            sla = var.get("sla")
            if isinstance(sla, Mapping) and sla.get("value") and "delivery_eta" not in attributes:
                attributes["delivery_eta"] = clean(f"{sla.get('value')} {sla.get('unit', '')}", 30)
            rating = var.get("rating")
            if isinstance(rating, Mapping) and rating.get("value") and "rating" not in attributes:
                attributes["rating"] = clean(rating["value"], 10)
                if rating.get("count"):
                    attributes["rating_count"] = clean(rating["count"], 20)
        return Product(
            **stamp(self.id, ProviderMethod.SEARCH_PRODUCTS, at),
            provider=self.id,
            product_id=clean(raw["productId"], 80),
            name=clean(raw["displayName"]),
            brand=clean(raw["brand"], 80) if raw.get("brand") else None,
            variants=variants,
            attributes=attributes,
        )

    def _cart(self, data: Mapping[str, Any], method: ProviderMethod) -> ProviderCart:
        at = self.now()
        lines = [
            CartLine(
                product_id=clean(item.get("productId") or "", 80),
                variant_id=clean(item["spinId"], 80),
                sku_id=clean(item["skuId"], 80) if item.get("skuId") else None,
                quantity=max(1, min(int(item.get("quantity") or 1), 99)),
            )
            for item in data.get("items") or []
            if isinstance(item, Mapping) and item.get("spinId")
        ]
        raw_bill = data.get("billBreakdown")
        bill: Mapping[str, Any] = raw_bill if isinstance(raw_bill, Mapping) else {}
        fees: list[FeeLine] = []
        verbatim: list[tuple[str, str]] = []
        item_total: int | None = None
        for line in bill.get("lineItems") or []:
            if not isinstance(line, Mapping):
                continue
            label, value = clean(line.get("label") or "", 80), clean(line.get("value") or "", 40)
            verbatim.append((label, value))
            lowered = label.lower()
            amount = 0 if value.strip().lower() == "free" else rupees_to_paise(value)
            if "item total" in lowered:
                item_total = amount
                continue
            kind = next((k for key, k in _FEE_KINDS if key in lowered), None)
            if kind is not None and amount is not None:
                fees.append(
                    FeeLine(**stamp(self.id, method, at), kind=kind, label=label, amount_paise=amount)
                )
        raw_to_pay = bill.get("toPay")
        to_pay: Mapping[str, Any] = raw_to_pay if isinstance(raw_to_pay, Mapping) else {}
        warnings = [clean(data[k]) for k in ("cartWarning", "addressWarning") if isinstance(data.get(k), str)]
        return ProviderCart(
            **stamp(self.id, method, at),
            provider=self.id,
            lines=lines,
            item_total_paise=item_total,
            to_pay_paise=rupees_to_paise(to_pay.get("value")),
            fees=fees,
            bill_lines=verbatim,
            warnings=warnings,
        )

    # ---------------------------------------------------------------- contract

    async def search_products(
        self, query: str, *, location_ref: str | None = None, limit: int = 10
    ) -> SearchResults | Unavailable:
        method = ProviderMethod.SEARCH_PRODUCTS
        args: dict[str, Any] = {"query": query}
        if location_ref:
            args["addressId"] = location_ref
        data = await self._call(method, "search_products", args, query=query)
        if isinstance(data, Unavailable):
            return data
        at = self.now()
        raw = [p for p in data.get("products") or [] if isinstance(p, Mapping)]
        products = [p for p in (self._product(r, at) for r in raw) if p is not None][:limit]
        return SearchResults(**stamp(self.id, method, at), provider=self.id, query=query, products=products)

    async def get_cart(self) -> ProviderCart | Unavailable:
        data = await self._call(ProviderMethod.GET_CART, "get_cart", {})
        return data if isinstance(data, Unavailable) else self._cart(data, ProviderMethod.GET_CART)

    async def get_delivery_fee(self, *, location_ref: str | None = None) -> FeeSchedule | Unavailable:
        cart = await self.get_cart()
        if isinstance(cart, Unavailable):
            return cart.model_copy(update={"method": ProviderMethod.GET_DELIVERY_FEE})
        return FeeSchedule(
            source=cart.source, retrieved_at=cart.retrieved_at, provider=self.id, fees=cart.fees
        )

    async def add_to_cart(
        self, lines: list[CartLine], *, location_ref: str | None = None
    ) -> ProviderCart | Unavailable:
        """Swiggy's `update_cart` replaces the whole cart with exactly these lines."""
        method = ProviderMethod.ADD_TO_CART
        if not location_ref:
            return self.unavailable(method, "address_required", "Choose a saved Swiggy address first.")
        items = [{"spinId": ln.variant_id, "skuId": ln.sku_id, "quantity": ln.quantity} for ln in lines]
        data = await self._call(method, "update_cart", {"selectedAddressId": location_ref, "items": items})
        return data if isinstance(data, Unavailable) else self._cart(data, method)

    async def prepare_checkout(
        self, lines: list[CartLine], *, location_ref: str | None = None
    ) -> CheckoutHandoff | Unavailable:
        cart = await self.add_to_cart(lines, location_ref=location_ref)
        if isinstance(cart, Unavailable):
            return cart.model_copy(update={"method": ProviderMethod.PREPARE_CHECKOUT})
        handoff = self.handoff()
        if handoff is None:
            return self.unavailable(ProviderMethod.PREPARE_CHECKOUT, "no_handoff_configured")
        return CheckoutHandoff(
            source=cart.source,
            retrieved_at=cart.retrieved_at,
            provider=self.id,
            cart_prepared=True,
            to_pay_paise=cart.to_pay_paise,
            handoff=handoff,
        )
