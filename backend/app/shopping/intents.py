"""Local intents for shopping (no model needed): keywords in en / hi / hinglish plus slot extraction."""

from __future__ import annotations

import re
from typing import Any

from app.core.types import AgentId
from app.shopping.references import WORKING_SET, parse_quantity, resolve_reference
from app.shopping.tools_common import BASKET_ITEMS
from app.tools.intents import IntentContext, IntentSpec

_SEARCH = re.compile(
    r"^(?:please\s+)?(?:search\s+(?:for\s+)?|find\s+(?:me\s+)?|show\s+me\s+|price\s+of\s+|how\s+much\s+is\s+)"
    r"|\s*(?:dhundo|dhoondo|search\s+karo|ka\s+price\s+batao|kitne\s+ka\s+hai|ढूंढो|खोजो|का\s+दाम\s+बताओ|की\s+कीमत\s+बताओ)\s*[?।]?$",
    re.I,
)
_ADD = re.compile(r"\b(add|more|aur|daal|dal\s+do|jodo)\b|जोड़|डाल|और", re.I)
_REMOVE = re.compile(r"\b(remove|delete|hata\s*do|hatao|nikal\s*do)\b|हटा|निकाल", re.I)
_BASKET = re.compile(r"\b(basket|cart|tokri)\b|टोकरी|कार्ट", re.I)
_SHOW = re.compile(r"\b(show|view|what'?s\s+in|dikhao|dikha\s*do)\b|दिखाओ|दिखा", re.I)
_COMPARE = re.compile(r"\b(compare|cheapest|sabse\s+sasta|kahan\s+sasta)\b|सबसे\s+सस्ता|तुलना", re.I)


def extract_search(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    query = _SEARCH.sub("", text.strip()).strip(" ?।")
    if not query or query == text.strip().strip(" ?।"):
        return None
    return {"query": query[:120]}


def extract_add(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    items = list(ctx.working_sets.get(WORKING_SET, []))
    if not items or not _ADD.search(text) or _REMOVE.search(text):
        return None
    selected = ctx.app_state.get("selected_product_ref")
    resolution = resolve_reference(
        text,
        items,
        lang=ctx.lang,
        selected_ref=selected if isinstance(selected, str) else None,
        implicit=True,
    )
    slots: dict[str, Any] = {"reference": text}
    if resolution.status == "resolved" and resolution.item is not None:
        slots = {"ref": resolution.item.get("ref"), "reference": text}
    spoken = parse_quantity(text)
    if spoken.quantity is not None:
        slots["quantity"] = spoken.quantity
    if spoken.variant_hint:
        slots["variant_hint"] = spoken.variant_hint
    return slots


def extract_remove(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    if not _REMOVE.search(text):
        return None
    items = list(ctx.working_sets.get(BASKET_ITEMS, []))
    resolution = resolve_reference(text, items, lang=ctx.lang, implicit=True)
    if resolution.status == "resolved" and resolution.item is not None:
        return {"item_id": resolution.item.get("ref")}
    return {"reference": text}


def extract_view(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    return {} if _BASKET.search(text) and _SHOW.search(text) else None


def extract_compare(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    return {} if _COMPARE.search(text) else None


INTENTS: tuple[IntentSpec, ...] = (
    IntentSpec(
        name="shopping.search",
        agent=AgentId.SHOPPING,
        tool="shopping.search_products",
        keywords={
            "en": ["search for", "find", "price of", "how much is"],
            "hi": ["ढूंढो", "खोजो", "का दाम बताओ", "की कीमत बताओ"],
            "hinglish": ["dhundo", "search karo", "ka price batao", "kitne ka hai"],
        },
        extract=extract_search,
        examples=("search for basmati rice 1 kg", "atta dhundo", "दूध खोजो"),
    ),
    IntentSpec(
        name="shopping.add",
        agent=AgentId.SHOPPING,
        tool="shopping.basket_add",
        keywords={
            "en": ["add", "the second one", "two more"],
            "hi": ["जोड़ो", "दूसरा वाला", "दो और"],
            "hinglish": ["add karo", "doosra wala", "do aur"],
        },
        extract=extract_add,
        priority=5,
        examples=("add the second one", "doosra wala add karo", "दूसरा वाला जोड़ो", "add two more packets"),
    ),
    IntentSpec(
        name="shopping.remove",
        agent=AgentId.SHOPPING,
        tool="shopping.basket_remove",
        keywords={"en": ["remove", "delete"], "hi": ["हटाओ", "निकालो"], "hinglish": ["hata do", "nikal do"]},
        extract=extract_remove,
        priority=5,
        examples=("remove the first item", "pehla wala hata do"),
    ),
    IntentSpec(
        name="shopping.basket_view",
        agent=AgentId.SHOPPING,
        tool="shopping.basket_view",
        keywords={
            "en": ["show my basket", "what's in my cart"],
            "hi": ["टोकरी दिखाओ"],
            "hinglish": ["basket dikhao", "tokri dikhao"],
        },
        extract=extract_view,
        examples=("show my basket",),
    ),
    IntentSpec(
        name="shopping.compare",
        agent=AgentId.SHOPPING,
        tool="shopping.compare_basket",
        keywords={
            "en": ["compare my basket", "compare this basket", "compare the basket", "where is it cheapest"],
            "hi": ["सबसे सस्ता कहाँ", "तुलना करो"],
            "hinglish": ["sabse sasta kahan", "compare karo"],
        },
        extract=extract_compare,
        examples=("where is my basket cheapest",),
    ),
)
