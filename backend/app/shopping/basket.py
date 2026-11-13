"""UniversalBasket service: items with a standardised identity, prices with provenance, comparison inputs."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any, Literal

from pydantic import AwareDatetime, Field
from sqlalchemy import or_, select

from app.core.clock import Clock
from app.core.errors import BadRequest, NotFound
from app.core.money import from_paise, to_paise
from app.db.base import new_id
from app.db.session import SessionFactory
from app.shopping.compare import BasketLineIn, FeeRule, OfferIn
from app.shopping.models import BasketItem, PriceObservation, ShoppingBasket
from app.shopping.normalize import identity_key, normalize_gtin, parse_pack
from app.shopping.types import Product, Provenance, SModel, Variant

ObservationKind = Literal[
    "item", "delivery_fee", "handling_fee", "platform_fee", "small_cart_fee", "other_fee"
]
MAX_QUANTITY = 99


class BasketItemView(SModel):
    item_id: str
    name: str
    brand: str | None
    size: str | None
    identity_key: str
    gtin: str | None
    sku: str | None
    selected_variant: dict[str, Any] | None
    quantity: int
    preferred_brand: str | None
    substitutions_allowed: bool
    equivalence_confidence_pct: int
    unit_price: Decimal | None
    price_at: datetime | None
    price_source: str | None
    available_retailers: list[dict[str, Any]]


class BasketView(SModel):
    basket_id: str
    name: str
    customer_location_reference: str | None
    original_provider: str | None
    items: list[BasketItemView]
    priced_items: int
    known_total: Decimal  # sum of priced lines only; `priced_items` says how many
    created_at: datetime
    updated_at: datetime


class PriceRecord(SModel):
    provider: str
    kind: ObservationKind = "item"
    item_id: str | None = None
    price: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    mrp: Decimal | None = Field(default=None, ge=0, max_digits=12, decimal_places=2)
    provenance: Provenance = "user_reported"
    observed_at: AwareDatetime | None = None
    match_kind: Literal["exact", "substitute"] = "exact"
    match_confidence_pct: int = Field(default=100, ge=0, le=100)
    match_reasons: list[str] = Field(default_factory=list)
    label: str = Field(default="", max_length=200)
    in_stock: bool | None = None
    product_id: str | None = None
    variant_id: str | None = None
    source: str | None = None


def item_view(item: BasketItem) -> BasketItemView:
    return BasketItemView(
        item_id=item.id,
        name=item.name,
        brand=item.brand,
        size=item.size_label,
        identity_key=item.identity_key,
        gtin=item.gtin,
        sku=item.sku,
        selected_variant=item.selected_variant,
        quantity=item.quantity,
        preferred_brand=item.preferred_brand,
        substitutions_allowed=item.substitutions_allowed,
        equivalence_confidence_pct=item.equivalence_confidence_pct,
        unit_price=from_paise(item.price_paise) if item.price_paise is not None else None,
        price_at=item.price_at,
        price_source=item.price_source,
        available_retailers=list(item.available_retailers or []),
    )


def basket_view(basket: ShoppingBasket) -> BasketView:
    priced = [i for i in basket.items if i.price_paise is not None]
    return BasketView(
        basket_id=basket.id,
        name=basket.name,
        customer_location_reference=basket.customer_location_reference,
        original_provider=basket.original_provider,
        items=[item_view(i) for i in basket.items],
        priced_items=len(priced),
        known_total=from_paise(sum((i.price_paise or 0) * i.quantity for i in priced)),
        created_at=basket.created_at,
        updated_at=basket.updated_at,
    )


class BasketService:
    def __init__(self, session_factory: SessionFactory, clock: Clock) -> None:
        self._sf = session_factory
        self._clock = clock

    async def _load(self, session: Any, basket_id: str | None, *, create: bool) -> ShoppingBasket:
        if basket_id is not None:
            basket = await session.get(ShoppingBasket, basket_id)
            if basket is None:
                raise NotFound("No basket with that id.", code="basket_not_found")
            return basket  # type: ignore[no-any-return]
        stmt = (
            select(ShoppingBasket)
            .where(ShoppingBasket.status == "active")
            .order_by(ShoppingBasket.created_at)
        )
        basket = (await session.scalars(stmt)).first()
        if basket is None:
            if not create:
                raise NotFound("There is no basket yet.", code="basket_not_found")
            now = self._clock.now()
            basket = ShoppingBasket(
                id=new_id("bkt"), name="Basket", status="active", created_at=now, updated_at=now
            )
            session.add(basket)
            await session.flush()
            await session.refresh(basket, ["items"])
        return basket  # type: ignore[no-any-return]

    async def view(self, basket_id: str | None = None, *, create: bool = True) -> BasketView:
        async with self._sf() as session:
            basket = await self._load(session, basket_id, create=create)
            await session.commit()
            return basket_view(basket)

    async def set_location(self, basket_id: str | None, location_ref: str | None) -> BasketView:
        async with self._sf() as session:
            basket = await self._load(session, basket_id, create=True)
            basket.customer_location_reference = location_ref
            basket.updated_at = self._clock.now()
            await session.commit()
            return basket_view(basket)

    async def add_product(
        self,
        product: Product,
        variant: Variant,
        *,
        quantity: int,
        mode: Literal["set", "add"] = "add",
        basket_id: str | None = None,
        substitutions_allowed: bool = False,
        preferred_brand: str | None = None,
    ) -> tuple[BasketView, BasketItemView]:
        pack = variant.pack or parse_pack(variant.label) or parse_pack(product.name)
        key = identity_key(product.brand, product.name, pack)
        now = self._clock.now()
        async with self._sf() as session:
            basket = await self._load(session, basket_id, create=True)
            existing = next((i for i in basket.items if i.identity_key == key), None)
            if existing is None:
                existing = BasketItem(
                    id=new_id("bki"),
                    basket_id=basket.id,
                    position=len(basket.items),
                    identity_key=key,
                    name=product.name,
                    brand=product.brand,
                    size_label=variant.label or (pack.label if pack else None),
                    pack_quantity=f"{pack.quantity.normalize():f}" if pack else None,
                    pack_unit=pack.unit if pack else None,
                    pack_count=pack.count if pack else 1,
                    gtin=normalize_gtin(product.gtin),
                    quantity=0,
                    preferred_brand=preferred_brand,
                    substitutions_allowed=substitutions_allowed,
                    equivalence_confidence_pct=100,
                    available_retailers=[],
                    created_at=now,
                    updated_at=now,
                )
                basket.items.append(existing)
            new_quantity = existing.quantity + quantity if mode == "add" else quantity
            if not 1 <= new_quantity <= MAX_QUANTITY:
                raise BadRequest(f"Quantity must be between 1 and {MAX_QUANTITY}.", code="invalid_quantity")
            existing.quantity = new_quantity
            existing.sku = variant.sku_id or existing.sku
            existing.selected_variant = {
                "provider": product.provider,
                "product_id": product.product_id,
                "variant_id": variant.variant_id,
                "sku_id": variant.sku_id,
                "label": variant.label,
            }
            if basket.original_provider is None:
                basket.original_provider = product.provider
            if variant.price_paise is not None:
                existing.price_paise = variant.price_paise
                existing.price_at = product.retrieved_at
                existing.price_source = product.source
                self._note_retailer(
                    existing,
                    product.provider,
                    product.product_id,
                    variant,
                    product.source,
                    product.retrieved_at,
                )
                session.add(
                    PriceObservation(
                        id=new_id("obs"),
                        basket_item_id=existing.id,
                        identity_key=key,
                        provider=product.provider,
                        kind="item",
                        product_id=product.product_id,
                        variant_id=variant.variant_id,
                        label=variant.label or product.name,
                        price_paise=variant.price_paise,
                        mrp_paise=variant.mrp_paise,
                        in_stock=variant.in_stock,
                        match_kind="exact",
                        match_confidence_pct=100,
                        match_reasons=[],
                        provenance="provider_api",
                        source=product.source,
                        observed_at=product.retrieved_at,
                        recorded_at=now,
                    )
                )
            existing.updated_at = basket.updated_at = now
            await session.commit()
            return basket_view(basket), item_view(existing)

    @staticmethod
    def _note_retailer(
        item: BasketItem,
        provider: str,
        product_id: str | None,
        variant: Variant | None,
        source: str,
        at: datetime,
    ) -> None:
        retailers = [r for r in (item.available_retailers or []) if r.get("provider") != provider]
        retailers.append(
            {
                "provider": provider,
                "product_id": product_id,
                "variant_id": variant.variant_id if variant else None,
                "price": str(from_paise(variant.price_paise))
                if variant and variant.price_paise is not None
                else None,
                "observed_at": at.isoformat(),
                "source": source,
            }
        )
        item.available_retailers = retailers

    async def set_quantity(self, item_id: str, quantity: int) -> tuple[BasketView, BasketItemView]:
        if not 1 <= quantity <= MAX_QUANTITY:
            raise BadRequest(f"Quantity must be between 1 and {MAX_QUANTITY}.", code="invalid_quantity")
        async with self._sf() as session:
            item = await session.get(BasketItem, item_id)
            if item is None:
                raise NotFound("No basket item with that id.", code="basket_item_not_found")
            item.quantity = quantity
            item.updated_at = self._clock.now()
            await session.commit()
            basket = await self._load(session, item.basket_id, create=False)
            return basket_view(basket), item_view(item)

    async def remove(self, item_id: str) -> tuple[BasketView, BasketItemView]:
        async with self._sf() as session:
            item = await session.get(BasketItem, item_id)
            if item is None:
                raise NotFound("No basket item with that id.", code="basket_item_not_found")
            removed = item_view(item)
            basket = await self._load(session, item.basket_id, create=False)
            basket.items.remove(item)
            basket.updated_at = self._clock.now()
            await session.commit()
            return basket_view(basket), removed

    async def record_price(self, record: PriceRecord) -> str:
        now = self._clock.now()
        observed = record.observed_at or now
        if observed > now:
            raise BadRequest("A price cannot be observed in the future.", code="invalid_observed_at")
        if record.kind == "item" and record.item_id is None:
            raise BadRequest("An item price needs the basket item.", code="item_required")
        async with self._sf() as session:
            item = await session.get(BasketItem, record.item_id) if record.item_id else None
            if record.item_id and item is None:
                raise NotFound("No basket item with that id.", code="basket_item_not_found")
            source = record.source or ("user" if record.provenance != "provider_api" else record.provider)
            price = to_paise(record.price)
            obs = PriceObservation(
                id=new_id("obs"),
                basket_item_id=record.item_id,
                identity_key=item.identity_key if item else None,
                provider=record.provider,
                kind=record.kind,
                product_id=record.product_id,
                variant_id=record.variant_id,
                label=record.label,
                price_paise=price,
                mrp_paise=to_paise(record.mrp) if record.mrp is not None else None,
                in_stock=record.in_stock,
                match_kind=record.match_kind,
                match_confidence_pct=record.match_confidence_pct,
                match_reasons=record.match_reasons,
                provenance=record.provenance,
                source=source,
                observed_at=observed,
                recorded_at=now,
            )
            session.add(obs)
            if item is not None and record.match_kind == "exact":
                variant = Variant(variant_id=record.variant_id or "", price_paise=price)
                self._note_retailer(item, record.provider, record.product_id, variant, source, observed)
            await session.commit()
            return obs.id

    async def compare_inputs(
        self, basket_id: str | None, *, create: bool = False
    ) -> tuple[BasketView, list[BasketLineIn], dict[str, list[OfferIn]], dict[str, list[FeeRule]]]:
        """Basket lines plus the latest observation per (provider, item, match kind) and fee rules."""
        async with self._sf() as session:
            basket = await self._load(session, basket_id, create=create)
            await session.commit()
            view = basket_view(basket)
            item_ids = [i.id for i in basket.items]
            rows = (
                await session.scalars(
                    select(PriceObservation)
                    .where(
                        or_(PriceObservation.basket_item_id.in_(item_ids), PriceObservation.kind != "item")
                    )
                    .order_by(PriceObservation.observed_at.desc(), PriceObservation.id)
                )
            ).all()
        lines = [
            BasketLineIn(
                item_id=i.item_id,
                name=i.name,
                quantity=i.quantity,
                substitutions_allowed=i.substitutions_allowed,
            )
            for i in view.items
        ]
        offers: dict[str, list[OfferIn]] = {}
        fees: dict[str, list[FeeRule]] = {}
        seen: set[tuple[str, str, str]] = set()
        for row in rows:
            if row.kind == "item":
                if row.basket_item_id not in item_ids:
                    continue
                key = (row.provider, row.basket_item_id or "", row.match_kind)
                if key in seen:
                    continue
                seen.add(key)
                offers.setdefault(row.provider, []).append(
                    OfferIn(
                        item_id=row.basket_item_id or "",
                        match_kind=row.match_kind,
                        confidence=row.match_confidence_pct / 100,
                        reasons=list(row.match_reasons or []),
                        unit_price_paise=row.price_paise,
                        observed_at=row.observed_at,
                        provenance=row.provenance,
                        source=row.source,
                        in_stock=row.in_stock,
                        label=row.label,
                    )
                )
            else:
                key = (row.provider, row.kind, "fee")
                if key in seen:
                    continue
                seen.add(key)
                fees.setdefault(row.provider, []).append(
                    FeeRule(
                        kind=row.kind,
                        label=row.label,
                        amount_paise=row.price_paise,
                        observed_at=row.observed_at,
                        provenance=row.provenance,
                        source=row.source,
                    )
                )
        return view, lines, offers, fees
