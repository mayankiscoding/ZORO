"""Basket tools: view, add, set quantity, remove, record a price."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Literal

from pydantic import Field

from app.core.errors import NotFound
from app.core.money import format_inr
from app.core.types import RiskLevel
from app.schemas.common import UICard
from app.shopping.basket import BasketItemView, BasketView, PriceRecord
from app.shopping.present import say_basket, say_clarify
from app.shopping.references import Clarification, parse_quantity
from app.shopping.service import ShoppingService
from app.shopping.tools_common import (
    AGENTS,
    BASKET_ITEMS,
    MCP_GROUP,
    PERM_BASKET,
    PERSONAL,
    Picked,
    ProductPick,
    pick_basket_item,
    pick_product,
)
from app.shopping.types import SModel
from app.tools.spec import ToolContext, ToolSpec


class BasketViewIn(SModel):
    basket_id: str | None = None


class BasketViewOut(SModel):
    basket: BasketView | None


class BasketAddIn(ProductPick):
    quantity: int | None = Field(default=None, ge=1, le=99)  # None: read it from `reference`, else 1
    mode: Literal["set", "add"] | None = None
    substitutions_allowed: bool = False
    preferred_brand: str | None = Field(default=None, max_length=80)
    basket_id: str | None = None


class SetQuantityIn(SModel):
    item_id: str | None = None
    reference: str | None = Field(default=None, max_length=300)
    quantity: int = Field(ge=1, le=99)


class RemoveIn(SModel):
    item_id: str | None = None
    reference: str | None = Field(default=None, max_length=300)


class BasketChangeOut(SModel):
    status: Literal["added", "updated", "removed", "needs_clarification", "not_found"]
    item: BasketItemView | None = None
    basket: BasketView | None = None
    clarification: Clarification | None = None


class RecordPriceIn(PriceRecord):
    reference: str | None = Field(default=None, max_length=300)  # basket item, e.g. "the second item"


class RecordPriceOut(SModel):
    status: Literal["recorded", "needs_clarification", "not_found"]
    observation_id: str | None = None
    provider: str
    kind: str
    price: Decimal
    provenance: str
    observed_at: datetime | None = None
    clarification: Clarification | None = None


async def _remember_basket(ctx: ToolContext, view: BasketView) -> None:
    await ctx.set_working_set(
        BASKET_ITEMS, [{"ref": i.item_id, "label": f"{i.name} {i.size or ''}".strip()} for i in view.items]
    )


async def _current(svc: ShoppingService, basket_id: str | None) -> list[BasketItemView]:
    try:
        return (await svc.baskets.view(basket_id, create=False)).items
    except NotFound:
        return []


def build_basket_tools(svc: ShoppingService) -> list[ToolSpec]:
    async def view(ctx: ToolContext, args: BasketViewIn) -> BasketViewOut:
        try:
            basket = await svc.baskets.view(args.basket_id, create=False)
        except NotFound:
            return BasketViewOut(basket=None)
        await _remember_basket(ctx, basket)
        return BasketViewOut(basket=basket)

    async def add(ctx: ToolContext, args: BasketAddIn) -> BasketChangeOut:
        spoken = parse_quantity(args.reference or "")
        pick = ProductPick(
            ref=args.ref, reference=args.reference, variant_hint=args.variant_hint or spoken.variant_hint
        )
        picked = await pick_product(ctx, pick)
        if picked.status != "resolved" or picked.product is None or picked.variant is None:
            return BasketChangeOut(
                status="needs_clarification" if picked.status == "needs_clarification" else "not_found",
                clarification=picked.clarification,
            )
        quantity = args.quantity or spoken.quantity or 1
        mode = args.mode or "add"
        before = {i.identity_key for i in (await _current(svc, args.basket_id))}
        basket, item = await svc.baskets.add_product(
            picked.product,
            picked.variant,
            quantity=quantity,
            mode=mode,
            basket_id=args.basket_id,
            substitutions_allowed=args.substitutions_allowed,
            preferred_brand=args.preferred_brand,
        )
        await _remember_basket(ctx, basket)
        status: Literal["added", "updated"] = "updated" if item.identity_key in before else "added"
        return BasketChangeOut(status=status, item=item, basket=basket)

    async def _target(ctx: ToolContext, item_id: str | None, reference: str | None) -> str | BasketChangeOut:
        target = await pick_basket_item(ctx, item_id, reference)
        if isinstance(target, Picked):
            return BasketChangeOut(
                status="needs_clarification" if target.status == "needs_clarification" else "not_found",
                clarification=target.clarification,
            )
        return target

    async def set_quantity(ctx: ToolContext, args: SetQuantityIn) -> BasketChangeOut:
        target = await _target(ctx, args.item_id, args.reference)
        if isinstance(target, BasketChangeOut):
            return target
        basket, item = await svc.baskets.set_quantity(target, args.quantity)
        await _remember_basket(ctx, basket)
        return BasketChangeOut(status="updated", item=item, basket=basket)

    async def remove(ctx: ToolContext, args: RemoveIn) -> BasketChangeOut:
        target = await _target(ctx, args.item_id, args.reference)
        if isinstance(target, BasketChangeOut):
            return target
        basket, item = await svc.baskets.remove(target)
        await _remember_basket(ctx, basket)
        return BasketChangeOut(status="removed", item=item, basket=basket)

    async def record(ctx: ToolContext, args: RecordPriceIn) -> RecordPriceOut:
        record = PriceRecord.model_validate(args.model_dump(exclude={"reference"}))
        base = {
            "provider": args.provider,
            "kind": args.kind,
            "price": args.price,
            "provenance": args.provenance,
        }
        if args.kind == "item" and record.item_id is None:
            target = await pick_basket_item(ctx, None, args.reference)
            if isinstance(target, Picked):
                status = "needs_clarification" if target.status == "needs_clarification" else "not_found"
                return RecordPriceOut(**base, status=status, clarification=target.clarification)
            record.item_id = target
        obs_id = await svc.baskets.record_price(record)
        return RecordPriceOut(
            **base, status="recorded", observation_id=obs_id, observed_at=record.observed_at or ctx.now()
        )

    meta = {"data_classes": PERSONAL, "agents": AGENTS, "mcp_group": MCP_GROUP}
    return [
        ToolSpec(
            name="shopping.basket_view",
            description="Show the shopping basket with prices and their sources.",
            input_model=BasketViewIn,
            output_model=BasketViewOut,
            handler=view,
            risk=RiskLevel.LOW,
            permission=None,
            summarizer=_view_summary,
            card=_basket_card,
            **meta,  # type: ignore[arg-type]
        ),
        ToolSpec(
            name="shopping.basket_add",
            description="Add a product just shown (by ref or words like 'the second one', 'two more packets').",
            input_model=BasketAddIn,
            output_model=BasketChangeOut,
            handler=add,
            risk=RiskLevel.MEDIUM,
            permission=PERM_BASKET,
            summarizer=_change_summary,
            card=_change_card,
            **meta,  # type: ignore[arg-type]
        ),
        ToolSpec(
            name="shopping.basket_set_quantity",
            description="Set the quantity of a basket item.",
            input_model=SetQuantityIn,
            output_model=BasketChangeOut,
            handler=set_quantity,
            risk=RiskLevel.MEDIUM,
            permission=PERM_BASKET,
            summarizer=_change_summary,
            card=_change_card,
            **meta,  # type: ignore[arg-type]
        ),
        ToolSpec(
            name="shopping.basket_remove",
            description="Remove an item from the basket.",
            input_model=RemoveIn,
            output_model=BasketChangeOut,
            handler=remove,
            risk=RiskLevel.MEDIUM,
            permission=PERM_BASKET,
            summarizer=_change_summary,
            card=_change_card,
            **meta,  # type: ignore[arg-type]
        ),
        ToolSpec(
            name="shopping.record_price",
            description="Record a price or fee the owner saw (typed or from a screenshot), with its time.",
            input_model=RecordPriceIn,
            output_model=RecordPriceOut,
            handler=record,
            risk=RiskLevel.MEDIUM,
            permission=PERM_BASKET,
            summarizer=_record_summary,
            **meta,  # type: ignore[arg-type]
        ),
    ]


def _view_summary(r: BasketViewOut, lang: str) -> str:
    if r.basket is None:
        return {"hi": "अभी कोई टोकरी नहीं है।", "hinglish": "Abhi koi basket nahi hai."}.get(
            lang, "There is no basket yet."
        )
    return say_basket(len(r.basket.items), r.basket.priced_items, r.basket.known_total, lang)


def _basket_card(r: BasketViewOut) -> UICard | None:
    if r.basket is None:
        return None
    return UICard(kind="basket", title=r.basket.name, payload=r.basket.model_dump(mode="json"))


def _change_card(r: BasketChangeOut) -> UICard | None:
    return _basket_card(BasketViewOut(basket=r.basket)) if r.basket else None


def _change_summary(r: BasketChangeOut, lang: str) -> str:
    if r.item is None:
        if r.status == "not_found":
            return {"hi": "वह उत्पाद नहीं मिला।", "hinglish": "Woh product nahi mila."}.get(
                lang, "I could not find that product."
            )
        return say_clarify(lang)
    name, qty = r.item.name, r.item.quantity
    if r.status == "removed":
        return {"hi": f"{name} टोकरी से हटाया गया।", "hinglish": f"{name} basket se hata diya."}.get(
            lang, f"Removed {name} from your basket."
        )
    return {
        "hi": f"टोकरी में अब {name} की मात्रा {qty} है।",
        "hinglish": f"Basket mein ab {name} ki quantity {qty} hai.",
    }.get(lang, f"Your basket now has {qty} of {name}.")


def _record_summary(r: RecordPriceOut, lang: str) -> str:
    if r.status != "recorded":
        return say_clarify(lang)
    amount = format_inr(r.price)
    return {
        "hi": f"{r.provider} की कीमत {amount} दर्ज की गई।",
        "hinglish": f"{r.provider} ka price {amount} note kar liya.",
    }.get(lang, f"Recorded {amount} at {r.provider}.")
