"""Shared pieces of the shopping tools: static metadata and conversation reference resolution."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import Field

from app.core.types import AgentId, DataClass
from app.shopping.matching import resolve_variant
from app.shopping.present import product_from_working
from app.shopping.references import WORKING_SET, Clarification, resolve_reference
from app.shopping.types import Product, SModel, Variant
from app.tools.spec import ToolContext

MCP_GROUP = "shopping-mcp"
PERM_BASKET = "shopping.basket"
PERM_PROVIDER_CART = "shopping.provider_cart"
AGENTS = frozenset({AgentId.SHOPPING, AgentId.PERSONAL_ASSISTANT, AgentId.VOICE})
RESEARCH_AGENTS = AGENTS | {AgentId.PRODUCT_RESEARCH}
PUBLIC = frozenset({DataClass.PUBLIC})
PERSONAL = frozenset({DataClass.PERSONAL})
BASKET_ITEMS = "basket_items"


class ProductPick(SModel):
    """How a tool names a product: an exact `ref` from the last results, or the owner's words."""

    ref: str | None = Field(default=None, max_length=200)
    reference: str | None = Field(default=None, max_length=300)  # "the second one", "doosra wala"
    variant_hint: str | None = Field(default=None, max_length=60)  # "1 kg", or a variant id


class Picked(SModel):
    status: Literal["resolved", "needs_clarification", "not_found"]
    product: Product | None = None
    variant: Variant | None = None
    clarification: Clarification | None = None


def _variant_question(product: Product, options: list[Variant], lang: str) -> Clarification:
    question = {
        "hi": f"{product.name} का कौन सा साइज़?",
        "hinglish": f"{product.name} ka kaun sa size?",
    }.get(lang, f"Which size of {product.name}?")
    return Clarification(
        question=question,
        options=[
            {"index": i + 1, "variant_id": v.variant_id, "label": v.label} for i, v in enumerate(options)
        ],
    )


async def pick_product(ctx: ToolContext, pick: ProductPick, *, need_variant: bool = True) -> Picked:
    items = await ctx.working_set(WORKING_SET)
    item: dict[str, Any] | None = None
    if pick.ref:
        item = next((i for i in items if i.get("ref") == pick.ref), None)
        if item is None:
            return Picked(status="not_found")
    else:
        resolution = resolve_reference(pick.reference or "", items, lang=ctx.lang, implicit=True)
        if resolution.status == "none" or (resolution.status == "out_of_range" and not items):
            return Picked(status="not_found")
        if resolution.status != "resolved" or resolution.item is None:
            return Picked(status="needs_clarification", clarification=resolution.clarification)
        item = resolution.item
    product = product_from_working(item)
    if not need_variant:
        variant = product.variants[0] if len(product.variants) == 1 else None
        return Picked(status="resolved", product=product, variant=variant)
    chosen = resolve_variant(product, pick.variant_hint)
    if chosen.status == "resolved":
        return Picked(status="resolved", product=product, variant=chosen.variant)
    if not chosen.options:
        return Picked(status="not_found", product=product)
    return Picked(
        status="needs_clarification",
        product=product,
        clarification=_variant_question(product, chosen.options, ctx.lang),
    )


async def pick_basket_item(ctx: ToolContext, item_id: str | None, reference: str | None) -> Picked | str:
    """A basket item id, from an id or from "the second item" against the basket last shown."""
    if item_id:
        return item_id
    items = await ctx.working_set(BASKET_ITEMS)
    resolution = resolve_reference(reference or "", items, lang=ctx.lang, implicit=True)
    if resolution.status == "resolved" and resolution.item is not None:
        return str(resolution.item["ref"])
    if resolution.status == "none" or not items:
        return Picked(status="not_found")
    return Picked(status="needs_clarification", clarification=resolution.clarification)
