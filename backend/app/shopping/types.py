"""Shopping domain types. Every value a provider returns carries `source` and `retrieved_at`;
a method a provider cannot answer officially returns `Unavailable` (reason + handoff), never a guess.

Money is integer paise here (exact) and `Decimal` rupees only at the presentation edge.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from enum import StrEnum
from typing import Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field

from app.core.types import IntegrationLevel


class SModel(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class ProviderMethod(StrEnum):
    SEARCH_PRODUCTS = "search_products"
    GET_PRODUCT_DETAILS = "get_product_details"
    GET_AVAILABILITY = "get_availability"
    GET_CURRENT_PRICE = "get_current_price"
    GET_VARIANTS = "get_variants"
    GET_DELIVERY_ESTIMATE = "get_delivery_estimate"
    GET_DELIVERY_FEE = "get_delivery_fee"
    GET_APPLICABLE_DISCOUNTS = "get_applicable_discounts"
    ADD_TO_CART = "add_to_cart"
    GET_CART = "get_cart"
    PREPARE_CHECKOUT = "prepare_checkout"
    OPEN_PROVIDER_APP = "open_provider_app"


Provenance = Literal["provider_api", "user_reported", "user_screenshot_ocr"]


class Sourced(SModel):
    """Where a value came from and when."""

    source: str  # provider id + method, e.g. "swiggy_instamart:search_products", or "user"
    retrieved_at: AwareDatetime


class Handoff(SModel):
    """Open the provider's own page or app. Payment and ordering always finish there."""

    provider: str
    title: str
    url: str | None = None
    verified: bool = False  # URL format confirmed in official documentation
    note: str = ""


class Unavailable(SModel):
    kind: Literal["unavailable"] = "unavailable"
    provider: str
    method: ProviderMethod
    reason: str  # stable code: not_supported, requires_credentials, requires_partnership, provider_error …
    message: str = ""
    handoff: Handoff | None = None


class PackSize(SModel):
    """A pack expressed in base units (g, ml or count)."""

    quantity: Decimal  # per unit, in base units
    unit: Literal["g", "ml", "count"]
    count: int = 1  # multipack: number of units
    label: str = ""  # as written by the source, e.g. "2 x 500 g"

    @property
    def total(self) -> Decimal:
        return self.quantity * self.count


class Variant(SModel):
    variant_id: str  # provider id (Swiggy spinId, Flipkart product id, …)
    sku_id: str | None = None
    label: str = ""  # e.g. "1 kg"
    pack: PackSize | None = None
    price_paise: int | None = None
    mrp_paise: int | None = None
    in_stock: bool | None = None
    max_quantity: int | None = None


class Product(Sourced):
    provider: str
    product_id: str
    name: str
    brand: str | None = None
    gtin: str | None = None
    url: str | None = None
    variants: list[Variant] = Field(default_factory=list)
    attributes: dict[str, str] = Field(default_factory=dict)  # specs exactly as the source gave them


class SearchResults(Sourced):
    provider: str
    query: str
    products: list[Product]


class PriceQuote(Sourced):
    provider: str
    product_id: str
    variant_id: str | None = None
    price_paise: int
    mrp_paise: int | None = None


class Availability(Sourced):
    provider: str
    product_id: str
    variant_id: str | None = None
    in_stock: bool


class DeliveryEstimate(Sourced):
    provider: str
    value: str  # as the provider stated it, e.g. "12"
    unit: str  # e.g. "MINS"


class FeeLine(Sourced):
    kind: Literal["delivery_fee", "handling_fee", "platform_fee", "small_cart_fee", "other_fee"]
    label: str
    amount_paise: int


class DiscountRule(SModel):
    """A coupon or membership rule. Applied by deterministic code in `compare.py`."""

    code: str
    kind: Literal["percent", "flat", "free_delivery"]
    value: Decimal = Decimal(0)  # percent (e.g. 10) or rupees (flat)
    min_order_paise: int = 0
    cap_paise: int | None = None
    membership: bool = False  # membership rules always apply; coupons: the single best one applies
    source: str = "user_reported"


class FeeSchedule(Sourced):
    provider: str
    fees: list[FeeLine]


class DiscountList(Sourced):
    provider: str
    rules: list[DiscountRule]


class CartLine(SModel):
    product_id: str
    variant_id: str
    sku_id: str | None = None
    quantity: int = Field(ge=1, le=99)


class ProviderCart(Sourced):
    provider: str
    lines: list[CartLine]
    item_total_paise: int | None = None
    to_pay_paise: int | None = None
    fees: list[FeeLine] = Field(default_factory=list)
    bill_lines: list[tuple[str, str]] = Field(default_factory=list)  # labels/values verbatim
    warnings: list[str] = Field(default_factory=list)


class CheckoutHandoff(Sourced):
    provider: str
    cart_prepared: bool
    to_pay_paise: int | None = None
    handoff: Handoff


class MethodLevel(SModel):
    method: ProviderMethod
    level: IntegrationLevel
    note: str = ""


class ProviderInfo(SModel):
    id: str
    title: str
    category: str
    status: str  # CapabilityStatus value
    methods: list[MethodLevel]
    handoff: Handoff | None = None
    note: str = ""


def stamp(provider: str, method: ProviderMethod | str, at: datetime) -> dict[str, object]:
    """Helper for building `Sourced` values."""
    name = method.value if isinstance(method, ProviderMethod) else method
    return {"source": f"{provider}:{name}", "retrieved_at": at}
