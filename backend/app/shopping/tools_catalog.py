"""Catalogue, comparison and checkout tools."""

from __future__ import annotations

from decimal import Decimal
from typing import Literal

from pydantic import Field

from app.core.errors import NotFound
from app.core.money import format_inr
from app.core.types import DataClass, RiskLevel
from app.schemas.common import LabelValue, UICard
from app.shopping.basket import BasketView
from app.shopping.compare import ComparisonResult
from app.shopping.present import (
    ShownProduct,
    lowest_price,
    products_card,
    say_clarify,
    say_comparison,
    say_products,
    shown,
    working_item,
)
from app.shopping.references import WORKING_SET, Clarification
from app.shopping.service import CheckoutResult, ShoppingService
from app.shopping.shortlist import ShortlistEntry
from app.shopping.tools_common import (
    AGENTS,
    MCP_GROUP,
    PERM_BASKET,
    PERM_PROVIDER_CART,
    PERSONAL,
    PUBLIC,
    RESEARCH_AGENTS,
    ProductPick,
    pick_product,
)
from app.shopping.types import DiscountRule, SModel, Unavailable
from app.tools.spec import ApprovalView, ToolContext, ToolSpec

MAX_SHOWN = 10


class SearchIn(SModel):
    query: str = Field(min_length=1, max_length=120)
    providers: list[str] | None = None
    location_ref: str | None = Field(default=None, max_length=120)
    limit: int = Field(default=5, ge=1, le=10)


class SearchOut(SModel):
    query: str
    products: list[ShownProduct]
    unavailable: list[Unavailable]


class DetailsOut(SModel):
    status: Literal["ok", "needs_clarification", "not_found"]
    product: ShownProduct | None = None
    live: Unavailable | None = None  # why fresher details could not be fetched
    clarification: Clarification | None = None


class ShortlistOut(SModel):
    status: Literal["added", "needs_clarification", "not_found"]
    entry: ShortlistEntry | None = None
    clarification: Clarification | None = None


class ProviderDiscount(SModel):
    provider: str
    rule: DiscountRule


class CompareIn(SModel):
    basket_id: str | None = None
    discounts: list[ProviderDiscount] = Field(default_factory=list)


class CompareOut(SModel):
    basket: BasketView | None
    comparison: ComparisonResult | None


class CheckoutIn(SModel):
    provider: str = Field(min_length=1, max_length=64)
    expected_payable: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    location_ref: str | None = Field(default=None, max_length=120)
    basket_id: str | None = None


def build_catalog_tools(svc: ShoppingService) -> list[ToolSpec]:
    async def search(ctx: ToolContext, args: SearchIn) -> SearchOut:
        outcome = await svc.search(
            args.query, providers=args.providers, location_ref=args.location_ref, limit=args.limit
        )
        products = [p for r in outcome.results for p in r.products][:MAX_SHOWN]
        await ctx.set_working_set(WORKING_SET, [working_item(p) for p in products])
        return SearchOut(
            query=args.query,
            products=[shown(p, i + 1) for i, p in enumerate(products)],
            unavailable=outcome.unavailable,
        )

    async def details(ctx: ToolContext, args: ProductPick) -> DetailsOut:
        picked = await pick_product(ctx, args, need_variant=False)
        if picked.status == "needs_clarification":
            return DetailsOut(status="needs_clarification", clarification=picked.clarification)
        if picked.product is None:
            return DetailsOut(status="not_found")
        product, live = picked.product, None
        provider = svc.hub.get(product.provider)
        if provider is not None:
            fresh = await provider.get_product_details(product.product_id)
            if isinstance(fresh, Unavailable):
                live = fresh
            else:
                product = fresh
        return DetailsOut(status="ok", product=shown(product, 1), live=live)

    async def shortlist_add(ctx: ToolContext, args: ProductPick) -> ShortlistOut:
        picked = await pick_product(ctx, args, need_variant=False)
        if picked.status == "needs_clarification":
            return ShortlistOut(status="needs_clarification", clarification=picked.clarification)
        if picked.product is None:
            return ShortlistOut(status="not_found")
        return ShortlistOut(status="added", entry=await svc.shortlist.add(picked.product, picked.variant))

    async def compare(ctx: ToolContext, args: CompareIn) -> CompareOut:
        rules: dict[str, list[DiscountRule]] = {}
        for d in args.discounts:
            rules.setdefault(d.provider, []).append(d.rule)
        try:
            view, result = await svc.compare(args.basket_id, rules)
        except NotFound:
            return CompareOut(basket=None, comparison=None)
        return CompareOut(basket=view, comparison=result)

    async def checkout(ctx: ToolContext, args: CheckoutIn) -> CheckoutResult:
        return await svc.prepare_checkout(
            args.basket_id, args.provider, args.expected_payable, args.location_ref
        )

    def checkout_view(args: CheckoutIn) -> ApprovalView:
        provider = svc.hub.get(args.provider)
        title = provider.config.title if provider is not None else args.provider
        return ApprovalView(
            title=f"Prepare your {title} cart",
            summary=(
                f"Replace your {title} cart with this basket and open {title} to pay "
                f"{format_inr(args.expected_payable)}. ZORO does not pay."
            ),
            details=(
                LabelValue(label="Provider", value=title),
                LabelValue(label="Expected payable", value=format_inr(args.expected_payable)),
                LabelValue(label="Delivery address reference", value=args.location_ref or "basket default"),
            ),
        )

    return [
        ToolSpec(
            name="shopping.search_products",
            description="Search products at providers with an official route; others return their own search link.",
            input_model=SearchIn,
            output_model=SearchOut,
            handler=search,
            risk=RiskLevel.LOW,
            data_classes=PUBLIC,
            permission=None,
            agents=RESEARCH_AGENTS,
            mcp_group=MCP_GROUP,
            untrusted_output=True,
            timeout_s=30,
            summarizer=lambda r, lang: say_products(len(r.products), r.query, lowest_price(r.products), lang),
            card=lambda r: products_card(r.products, r.query),
        ),
        ToolSpec(
            name="shopping.product_details",
            description="Details of a product the owner was just shown (by ref or words like 'the second one').",
            input_model=ProductPick,
            output_model=DetailsOut,
            handler=details,
            risk=RiskLevel.LOW,
            data_classes=PUBLIC,
            permission=None,
            agents=RESEARCH_AGENTS,
            mcp_group=MCP_GROUP,
            untrusted_output=True,
            timeout_s=30,
            summarizer=lambda r, lang: (
                say_clarify(lang)
                if r.product is None
                else say_products(1, r.product.name, lowest_price([r.product]), lang)
            ),
            card=lambda r: products_card([r.product], r.product.name) if r.product else None,
        ),
        ToolSpec(
            name="shopping.shortlist_add",
            description="Add a product the owner was just shown to the research shortlist.",
            input_model=ProductPick,
            output_model=ShortlistOut,
            handler=shortlist_add,
            risk=RiskLevel.MEDIUM,
            data_classes=PERSONAL,
            permission=PERM_BASKET,
            agents=RESEARCH_AGENTS,
            mcp_group=MCP_GROUP,
            summarizer=lambda r, lang: (
                say_clarify(lang)
                if r.entry is None
                else {
                    "hi": f"{r.entry.name} शॉर्टलिस्ट में जोड़ा गया।",
                    "hinglish": f"{r.entry.name} shortlist mein add ho gaya.",
                }.get(lang, f"Added {r.entry.name} to your shortlist.")
            ),
        ),
        ToolSpec(
            name="shopping.compare_basket",
            description="Compare the basket across providers: exact matches, fees, coupons, coverage, freshness.",
            input_model=CompareIn,
            output_model=CompareOut,
            handler=compare,
            risk=RiskLevel.LOW,
            data_classes=PERSONAL,
            permission=None,
            agents=AGENTS,
            mcp_group=MCP_GROUP,
            summarizer=_compare_summary,
            card=_compare_card,
        ),
        ToolSpec(
            name="shopping.prepare_checkout",
            description="Verify the basket and prepare the provider cart (or hand off). Payment stays in the provider's app.",
            input_model=CheckoutIn,
            output_model=CheckoutResult,
            handler=checkout,
            risk=RiskLevel.HIGH,
            data_classes=frozenset({DataClass.PERSONAL, DataClass.FINANCIAL}),
            permission=PERM_PROVIDER_CART,
            agents=AGENTS,
            mcp_group=MCP_GROUP,
            timeout_s=45,
            summarizer=_checkout_summary,
            approval_view=checkout_view,
        ),
    ]


def _compare_summary(r: CompareOut, lang: str) -> str:
    c = r.comparison
    if c is None:
        return {"hi": "अभी कोई टोकरी नहीं है।", "hinglish": "Abhi koi basket nahi hai."}.get(
            lang, "There is no basket yet."
        )
    ranked = [p for p in c.providers if p.status == "ranked"]
    partial = [p for p in c.providers if p.status == "partial"]
    best = next((p for p in ranked if p.provider == c.cheapest_provider), None)
    return say_comparison(
        best.title if best else None,
        best.final_payable if best else None,
        len(ranked),
        len(partial),
        c.cheapest_reason,
        lang,
    )


def _compare_card(r: CompareOut) -> UICard | None:
    if r.comparison is None:
        return None
    return UICard(
        kind="basket_comparison", title="Basket comparison", payload=r.comparison.model_dump(mode="json")
    )


def _checkout_summary(r: CheckoutResult, lang: str) -> str:
    if r.status == "rejected":
        return {
            "hi": f"कार्ट तैयार नहीं हुआ: {r.reason}।",
            "hinglish": f"Cart ready nahi hua: {r.reason}.",
        }.get(lang, f"The cart was not prepared: {r.reason}.")
    if r.status == "cart_prepared":
        return {
            "hi": f"{r.provider} कार्ट तैयार है; भुगतान उसी ऐप में करें।",
            "hinglish": f"{r.provider} cart ready hai; payment usi app mein karein.",
        }.get(lang, f"Your {r.provider} cart is ready; pay in the {r.provider} app.")
    return {
        "hi": f"{r.provider} खोलें और वहीं ऑर्डर पूरा करें।",
        "hinglish": f"{r.provider} kholiye aur wahin order poora kijiye.",
    }.get(lang, f"Open {r.provider} to finish the order there.")
