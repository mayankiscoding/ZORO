"""Shortlist of products the owner is considering (service ``shopping_shortlist``).

Each entry keeps the attributes exactly as the provider returned them, with source and time, so
product research can compare them without inventing anything.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from sqlalchemy import select

from app.core.clock import Clock
from app.core.money import from_paise
from app.db.base import new_id
from app.db.session import SessionFactory
from app.shopping.models import ShortlistItem
from app.shopping.types import Product, SModel, Variant


class ShortlistEntry(SModel):
    entry_id: str
    provider: str
    product_id: str
    variant_id: str | None
    name: str
    brand: str | None
    url: str | None
    price: Decimal | None
    attributes: dict[str, str]
    source: str
    retrieved_at: datetime


def _entry(row: ShortlistItem) -> ShortlistEntry:
    return ShortlistEntry(
        entry_id=row.id,
        provider=row.provider,
        product_id=row.product_id,
        variant_id=row.variant_id,
        name=row.name,
        brand=row.brand,
        url=row.url,
        price=from_paise(row.price_paise) if row.price_paise is not None else None,
        attributes=dict(row.attributes or {}),
        source=row.source,
        retrieved_at=row.retrieved_at,
    )


class ShortlistService:
    def __init__(self, session_factory: SessionFactory, clock: Clock) -> None:
        self._sf = session_factory
        self._clock = clock

    async def add(self, product: Product, variant: Variant | None) -> ShortlistEntry:
        async with self._sf() as session:
            existing = (
                await session.scalars(
                    select(ShortlistItem).where(
                        ShortlistItem.provider == product.provider,
                        ShortlistItem.product_id == product.product_id,
                    )
                )
            ).first()
            row = existing or ShortlistItem(id=new_id("sli"), created_at=self._clock.now())
            row.provider, row.product_id = product.provider, product.product_id
            row.variant_id = variant.variant_id if variant else None
            row.name, row.brand, row.url = product.name, product.brand, product.url
            row.price_paise = variant.price_paise if variant else None
            attributes = dict(product.attributes)
            if variant is not None and variant.label:
                attributes.setdefault("size", variant.label)
            row.attributes = attributes
            row.source, row.retrieved_at = product.source, product.retrieved_at
            if existing is None:
                session.add(row)
            await session.commit()
            return _entry(row)

    async def list(self) -> list[ShortlistEntry]:
        async with self._sf() as session:
            rows = (await session.scalars(select(ShortlistItem).order_by(ShortlistItem.created_at))).all()
            return [_entry(r) for r in rows]
