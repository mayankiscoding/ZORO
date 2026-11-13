"""Shopping tables: universal basket, its items, price observations (with provenance), shortlist.

Money is integer paise. Every price row says where it came from and when.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import BigInteger, Boolean, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, UTCDateTime
from app.db.types import JSONType


class ShoppingBasket(Base):
    __tablename__ = "shopping_baskets"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(120), default="Basket")
    status: Mapped[str] = mapped_column(String(16), default="active", index=True)  # active | archived
    customer_location_reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    original_provider: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)

    items: Mapped[list[BasketItem]] = relationship(
        back_populates="basket", cascade="all, delete-orphan", order_by="BasketItem.position", lazy="selectin"
    )


class BasketItem(Base):
    __tablename__ = "shopping_basket_items"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    basket_id: Mapped[str] = mapped_column(ForeignKey("shopping_baskets.id", ondelete="CASCADE"), index=True)
    position: Mapped[int] = mapped_column(Integer, default=0)
    identity_key: Mapped[str] = mapped_column(String(300), index=True)  # standardised identity
    name: Mapped[str] = mapped_column(String(200))
    brand: Mapped[str | None] = mapped_column(String(80), nullable=True)
    size_label: Mapped[str | None] = mapped_column(String(60), nullable=True)
    pack_quantity: Mapped[str | None] = mapped_column(String(32), nullable=True)  # Decimal, base units
    pack_unit: Mapped[str | None] = mapped_column(String(8), nullable=True)  # g | ml | count
    pack_count: Mapped[int] = mapped_column(Integer, default=1)
    gtin: Mapped[str | None] = mapped_column(String(14), nullable=True)
    sku: Mapped[str | None] = mapped_column(String(80), nullable=True)
    selected_variant: Mapped[dict[str, Any] | None] = mapped_column(JSONType, nullable=True)
    quantity: Mapped[int] = mapped_column(Integer, default=1)
    preferred_brand: Mapped[str | None] = mapped_column(String(80), nullable=True)
    substitutions_allowed: Mapped[bool] = mapped_column(Boolean, default=False)
    equivalence_confidence_pct: Mapped[int] = mapped_column(Integer, default=100)
    price_paise: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_currency: Mapped[str] = mapped_column(String(3), default="INR")
    price_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    price_source: Mapped[str | None] = mapped_column(String(120), nullable=True)
    available_retailers: Mapped[list[dict[str, Any]]] = mapped_column(JSONType, default=list)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)

    basket: Mapped[ShoppingBasket] = relationship(back_populates="items")


class PriceObservation(Base):
    """One observed price (or fee) with provenance: provider_api | user_reported | user_screenshot_ocr."""

    __tablename__ = "shopping_price_observations"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    basket_item_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    identity_key: Mapped[str | None] = mapped_column(String(300), nullable=True, index=True)
    provider: Mapped[str] = mapped_column(String(64), index=True)
    kind: Mapped[str] = mapped_column(String(24), default="item")  # item | delivery_fee | handling_fee | …
    product_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    variant_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    label: Mapped[str] = mapped_column(String(200), default="")
    price_paise: Mapped[int] = mapped_column(BigInteger)
    mrp_paise: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    currency: Mapped[str] = mapped_column(String(3), default="INR")
    in_stock: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    match_kind: Mapped[str] = mapped_column(String(12), default="exact")  # exact | substitute
    match_confidence_pct: Mapped[int] = mapped_column(Integer, default=100)
    match_reasons: Mapped[list[str]] = mapped_column(JSONType, default=list)
    provenance: Mapped[str] = mapped_column(String(24))
    source: Mapped[str] = mapped_column(String(120))
    observed_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    recorded_at: Mapped[datetime] = mapped_column(UTCDateTime)


class ShortlistItem(Base):
    __tablename__ = "shopping_shortlist"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    provider: Mapped[str] = mapped_column(String(64))
    product_id: Mapped[str] = mapped_column(String(80))
    variant_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    name: Mapped[str] = mapped_column(String(200))
    brand: Mapped[str | None] = mapped_column(String(80), nullable=True)
    url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    price_paise: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    attributes: Mapped[dict[str, str]] = mapped_column(JSONType, default=dict)
    source: Mapped[str] = mapped_column(String(120))
    retrieved_at: Mapped[datetime] = mapped_column(UTCDateTime)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
