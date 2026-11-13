"""What the owner sees and hears: product DTOs with rupee amounts, cards, and one-sentence summaries
in en / hi (Devanagari) / hinglish built only from values in the result."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

from app.core.money import format_inr, from_paise
from app.schemas.common import UICard
from app.shopping.normalize import unit_price
from app.shopping.types import Product, SModel, Variant


class VariantOut(SModel):
    variant_id: str
    sku_id: str | None = None
    label: str = ""
    price: Decimal | None = None
    mrp: Decimal | None = None
    unit_price: str | None = None  # e.g. "₹12.50 per 100 g", computed from the price and size
    in_stock: bool | None = None


class ShownProduct(SModel):
    index: int  # 1-based, as shown
    ref: str  # stable reference inside this conversation
    provider: str
    product_id: str
    name: str
    brand: str | None = None
    url: str | None = None
    variants: list[VariantOut]
    attributes: dict[str, str]
    source: str
    retrieved_at: datetime


def variant_out(v: Variant) -> VariantOut:
    unit: str | None = None
    if v.price_paise is not None:
        computed = unit_price(v.price_paise, v.pack)
        unit = f"{format_inr(computed[0])} {computed[1]}" if computed else None
    return VariantOut(
        variant_id=v.variant_id,
        sku_id=v.sku_id,
        label=v.label,
        price=from_paise(v.price_paise) if v.price_paise is not None else None,
        mrp=from_paise(v.mrp_paise) if v.mrp_paise is not None else None,
        unit_price=unit,
        in_stock=v.in_stock,
    )


def product_ref(p: Product) -> str:
    return f"{p.provider}:{p.product_id}"


def shown(p: Product, index: int) -> ShownProduct:
    return ShownProduct(
        index=index,
        ref=product_ref(p),
        provider=p.provider,
        product_id=p.product_id,
        name=p.name,
        brand=p.brand,
        url=p.url,
        variants=[variant_out(v) for v in p.variants],
        attributes=p.attributes,
        source=p.source,
        retrieved_at=p.retrieved_at,
    )


def working_item(p: Product) -> dict[str, Any]:
    """What the conversation remembers: the product as retrieved plus its ref and a label."""
    data = p.model_dump(mode="json")
    data["ref"] = product_ref(p)
    data["label"] = p.name
    return data


def product_from_working(item: dict[str, Any]) -> Product:
    data = {k: v for k, v in item.items() if k not in ("ref", "label")}
    return Product.model_validate(data)


def _cheapest_price(products: list[ShownProduct]) -> Decimal | None:
    prices = [v.price for p in products for v in p.variants if v.price is not None]
    return min(prices) if prices else None


# ---------------------------------------------------------------- summaries (pure functions)


def say_products(count: int, query: str, lowest: Decimal | None, lang: str) -> str:
    if count == 0:
        return {
            "hi": f"“{query}” के लिए कोई उत्पाद नहीं मिला।",
            "hinglish": f"“{query}” ke liye koi product nahi mila.",
        }.get(lang, f"No products found for “{query}”.")
    price = format_inr(lowest) if lowest is not None else None
    if lang == "hi":
        tail = f" सबसे कम कीमत {price} है।" if price else ""
        return f"“{query}” के लिए {count} उत्पाद मिले।{tail}"
    if lang == "hinglish":
        tail = f" Sabse kam price {price} hai." if price else ""
        return f"“{query}” ke liye {count} products mile.{tail}"
    tail = f" The lowest price is {price}." if price else ""
    return f"Found {count} products for “{query}”.{tail}"


def say_basket(items: int, priced: int, total: Decimal, lang: str) -> str:
    amount = format_inr(total)
    if lang == "hi":
        return f"टोकरी में {items} आइटम हैं; {priced} की कीमत ज्ञात है, कुल {amount}।"
    if lang == "hinglish":
        return f"Basket mein {items} items hain; {priced} ka price pata hai, total {amount}."
    return f"Your basket has {items} items; {priced} are priced, totalling {amount}."


def say_clarify(lang: str) -> str:
    return {"hi": "आप कौन सा वाला चाहते हैं?", "hinglish": "Aap kaun sa wala chahte hain?"}.get(
        lang, "Which one do you mean?"
    )


def say_comparison(
    cheapest_title: str | None, payable: Decimal | None, ranked: int, partial: int, reason: str, lang: str
) -> str:
    if cheapest_title and payable is not None:
        amount = format_inr(payable)
        return {
            "hi": f"{cheapest_title} पर पूरी टोकरी सबसे सस्ती है: {amount}।",
            "hinglish": f"{cheapest_title} par poori basket sabse sasti hai: {amount}.",
        }.get(lang, f"{cheapest_title} is cheapest for the full basket at {amount}.")
    if ranked:
        return {
            "hi": f"{ranked} प्रदाताओं की पूरी कीमत मिली, पर कुछ शुल्क अज्ञात हैं, इसलिए सबसे सस्ता तय नहीं है।",
            "hinglish": f"{ranked} providers ka poora price mila, par kuch fees pata nahi, isliye sabse sasta tay nahi.",
        }.get(
            lang, f"{ranked} providers have full prices, but some fees are unknown, so no cheapest is named."
        )
    return {
        "hi": f"किसी प्रदाता के पास सभी आइटम की ताज़ा कीमत नहीं है; {partial} आंशिक हैं।",
        "hinglish": f"Kisi provider ke paas saare items ka fresh price nahi hai; {partial} partial hain.",
    }.get(lang, f"No provider has fresh prices for every item; {partial} are partial.")


def products_card(products: list[ShownProduct], query: str) -> UICard | None:
    if not products:
        return None
    return UICard(
        kind="products",
        title=query,
        payload={
            "products": [p.model_dump(mode="json") for p in products],
            "lowest_price": str(_cheapest_price(products)) if _cheapest_price(products) is not None else None,
        },
    )


def lowest_price(products: list[ShownProduct]) -> Decimal | None:
    return _cheapest_price(products)
