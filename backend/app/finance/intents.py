"""Finance intents for the local router: keywords in en / hi / hinglish and slot extraction.

Slots are plain period keys (see `periods`), category ids from config, merchant names from the
merchant alias table, and amounts as decimal strings. No model is involved.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Mapping, Sequence
from datetime import date
from typing import Any

from app.core.types import AgentId
from app.finance.categories import CategoryConfigSource
from app.finance.periods import MONTHS_EN, MONTHS_HI, local_today
from app.tools.intents import IntentContext, IntentSpec

_MONTH_WORDS: dict[str, int] = {}
for _i, _name in enumerate(MONTHS_EN, start=1):
    if _name != "May":  # "may" is also a verb: matched only as "in may" / "may 2026" below
        _MONTH_WORDS[_name.lower()] = _i
        _MONTH_WORDS[_name.lower()[:3]] = _i
_MONTH_WORDS["sept"] = 9
for _i, _name in enumerate(MONTHS_HI, start=1):
    _MONTH_WORDS[_name] = _i
_MONTH_WORDS.update({"फरवरी": 2, "सितम्बर": 9, "नवम्बर": 11, "दिसम्बर": 12, "farvari": 2, "farvary": 2})

_RELATIVE: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("last_month", ("last month", "previous month", "pichhle mahine", "pichle mahine", "pichhla mahina",
                    "pichla mahina", "पिछले महीने", "पिछला महीना", "पिछले माह")),
    ("this_month", ("this month", "is mahine", "iss mahine", "is month", "इस महीने", "इस माह")),
    ("last_year", ("last year", "previous year", "pichhle saal", "pichle saal", "pichhla saal", "पिछले साल",
                   "पिछला साल", "पिछले वर्ष")),
    ("this_year", ("this year", "is saal", "iss saal", "इस साल", "इस वर्ष")),
    ("last_week", ("last week", "pichhle hafte", "pichle hafte", "पिछले हफ़्ते", "पिछले हफ्ते", "पिछले सप्ताह")),
    ("this_week", ("this week", "is hafte", "iss hafte", "इस हफ़्ते", "इस हफ्ते", "इस सप्ताह")),
    ("today", ("today", "aaj", "आज")),
    ("yesterday", ("yesterday",)),
)  # fmt: skip
_LAST_N = re.compile(r"(?:last|past|pichhle|pichle|पिछले)\s+(\d{1,3})\s+(?:days|day|din|दिन|दिनों)")
_NEXT_N = re.compile(r"(?:next|agle|अगले)\s+(\d{1,3})\s+(?:days|day|din|दिन|दिनों)")
_YEAR = re.compile(r"(?<!\d)(20\d{2})(?!\d)")
_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")
_ORDINALS = {
    1: ("first", "1st", "pehla", "pehle", "pahla", "पहला", "पहले", "पहली"),
    2: ("second", "2nd", "doosra", "dusra", "doosre", "dusre", "दूसरा", "दूसरे", "दूसरी"),
    3: ("third", "3rd", "teesra", "tisra", "teesre", "तीसरा", "तीसरे", "तीसरी"),
    4: ("fourth", "4th", "chautha", "chauthe", "चौथा", "चौथे"),
    5: ("fifth", "5th", "paanchva", "panchva", "पाँचवा", "पांचवा"),
}


def _norm(text: str) -> str:
    return " " + re.sub(r"\s+", " ", text.lower().translate(_DIGITS)).strip() + " "


def _has(text: str, words: Sequence[str]) -> bool:
    return any((f" {w} " in text) if w.isascii() else (w in text) for w in words)


def parse_period(utterance: str, today: date) -> str | None:
    text = _norm(utterance)
    if m := _LAST_N.search(text):
        return f"last_{int(m.group(1))}_days"
    year_m = _YEAR.search(text)
    for word, month in sorted(_MONTH_WORDS.items(), key=lambda kv: -len(kv[0])):
        hit = (f" {word} " in text or f" {word}," in text) if word.isascii() else word in text
        if hit:
            year = (
                int(year_m.group(1)) if year_m else (today.year if month <= today.month else today.year - 1)
            )
            return f"{year:04d}-{month:02d}"
    if re.search(r"\b(in|of|for) may\b|\bmay (20\d{2})\b", text):
        year = int(year_m.group(1)) if year_m else (today.year if today.month >= 5 else today.year - 1)
        return f"{year:04d}-05"
    for key, phrases in _RELATIVE:
        if _has(text, phrases):
            return key
    return year_m.group(1) if year_m else None


def parse_amount_words(utterance: str) -> str | None:
    """ "5000", "5,000", "₹5k", "5 hazaar", "5 हज़ार", "2 lakh" -> a decimal string of rupees."""
    text = _norm(utterance).replace("₹", " ").replace("rs.", " ").replace("rs ", " ")
    m = re.search(
        r"(\d[\d,]*(?:\.\d{1,2})?)\s*(k|thousand|hazaar|hazar|हज़ार|हजार|lakh|lac|लाख)?(?![\d])", text
    )
    if not m:
        return None
    from decimal import Decimal

    value = Decimal(m.group(1).replace(",", ""))
    unit = m.group(2) or ""
    if unit in ("k", "thousand", "hazaar", "hazar", "हज़ार", "हजार"):
        value *= 1000
    elif unit in ("lakh", "lac", "लाख"):
        value *= 100_000
    return str(value.quantize(Decimal("0.01"))) if value > 0 else None


def parse_ordinal(utterance: str) -> int | None:
    text = _norm(utterance)
    for n, words in _ORDINALS.items():
        if _has(text, words):
            return n
    m = re.search(r"(?:number|no\.?|#|नंबर)\s*(\d{1,2})", text)
    return int(m.group(1)) if m else None


KW: dict[str, dict[str, tuple[str, ...]]] = {
    "spending": {"en": ("spent", "spend", "spending", "expenses", "expense"),
                 "hi": ("खर्च", "ख़र्च", "खर्चा"), "hinglish": ("kharch", "kharcha", "kharche", "spend kiya")},
    "breakdown": {"en": ("breakdown", "by category", "category wise", "categories"),
                  "hi": ("श्रेणी", "कैटेगरी"), "hinglish": ("category wise", "categories", "breakdown")},
    "income": {"en": ("income", "earned", "savings", "saved", "income vs"),
               "hi": ("आय", "कमाई", "बचत", "आमदनी"), "hinglish": ("kamai", "income", "bachat", "bachaya", "aamdani")},
    "transactions": {"en": ("transactions", "transaction", "payments list", "show payments", "statement"),
                     "hi": ("लेन-देन", "लेनदेन", "ट्रांज़ैक्शन"), "hinglish": ("transactions", "lenden", "len den")},
    "merchant": {"en": ("paid", "pay", "spent", "spend", "orders"),
                 "hi": ("दिए", "भुगतान", "खर्च"), "hinglish": ("diye", "payment", "kharch")},
    "recurring": {"en": ("subscriptions", "subscription", "recurring", "autopay", "auto debit"),
                  "hi": ("सदस्यता", "सब्सक्रिप्शन", "हर महीने"), "hinglish": ("subscription", "subscriptions", "har mahine")},
    "budget": {"en": ("budget",), "hi": ("बजट",), "hinglish": ("budget",)},
    "forecast": {"en": ("forecast", "cash flow", "cashflow", "upcoming", "next month"),
                 "hi": ("पूर्वानुमान", "अगले महीने", "अनुमान"), "hinglish": ("agle mahine", "forecast", "anumaan")},
    "set_budget": {"en": ("set", "make it", "change", "limit"), "hi": ("रखो", "तय", "सेट", "कर दो"),
                   "hinglish": ("set", "rakho", "rakh do", "fix", "kar do")},
    "recategorize": {"en": ("move", "mark", "categorise", "categorize", "recategorise", "put"),
                     "hi": ("में डालो", "में डाल", "बदलो"), "hinglish": ("daal do", "daalo", "dalo", "mark karo")},
}  # fmt: skip


def _any_kw(text: str, group: str) -> bool:
    return any(_has(text, words) for words in KW[group].values())


def build_intents(categories: CategoryConfigSource) -> list[IntentSpec]:
    def common(utterance: str, ctx: IntentContext, default_period: str) -> dict[str, Any]:
        today = local_today(ctx.now, ctx.timezone)
        return {"period": parse_period(utterance, today) or default_period}

    def merchant_in(utterance: str) -> str | None:
        text = _norm(utterance)
        hits = [name for alias, name in categories.current().merchants.items() if f" {alias} " in text]
        return max(hits, key=len) if hits else None

    def spending(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        text = _norm(u)
        if not _any_kw(text, "spending") or merchant_in(u) or _any_kw(text, "breakdown"):
            return None
        slots = common(u, ctx, "this_month")
        if (cat := categories.current().match_words(u)) is not None:
            slots["category"] = cat
        return slots

    def breakdown(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        return common(u, ctx, "this_month") if _any_kw(_norm(u), "breakdown") else None

    def income(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        return common(u, ctx, "this_year") if _any_kw(_norm(u), "income") else None

    def transactions(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        if not _any_kw(_norm(u), "transactions"):
            return None
        slots = common(u, ctx, "last_30_days")
        if (cat := categories.current().match_words(u)) is not None:
            slots["category"] = cat
        if (merchant := merchant_in(u)) is not None:
            slots["merchant"] = merchant
        return slots

    def merchant(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        name = merchant_in(u)
        if name is None or not _any_kw(_norm(u), "merchant") or _any_kw(_norm(u), "transactions"):
            return None
        return {**common(u, ctx, "this_month"), "merchant": name}

    def recurring(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        return {} if _any_kw(_norm(u), "recurring") else None

    def budget(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        text = _norm(u)
        if not _any_kw(text, "budget") or (_any_kw(text, "set_budget") and parse_amount_words(u)):
            return None
        cat = categories.current().match_words(u)
        return {"category": cat} if cat else {}

    def forecast(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        text = _norm(u)
        if not _any_kw(text, "forecast"):
            return None
        m = _NEXT_N.search(text)
        days = min(max(int(m.group(1)), 7), 90) if m else 30
        return {"horizon_days": days}

    def set_budget(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        text = _norm(u)
        amount = parse_amount_words(u)
        if not (_any_kw(text, "budget") and _any_kw(text, "set_budget")) or amount is None:
            return None
        return {"category": categories.current().match_words(u) or "all", "limit": amount}

    def recategorize(u: str, ctx: IntentContext) -> dict[str, Any] | None:
        shown = ctx.working_sets.get("transactions") or []
        position, cat = parse_ordinal(u), categories.current().match_words(u)
        if not shown or position is None or cat is None or not _any_kw(_norm(u), "recategorize"):
            return None
        if position > len(shown):
            return None
        return {"position": position, "category": cat, "apply_to_merchant": False}

    def spec(name: str, tool: str, group: str, fn: Callable[[str, IntentContext], dict[str, Any] | None],
             examples: Sequence[str], priority: int = 0) -> IntentSpec:  # fmt: skip
        words: Mapping[str, Sequence[str]] = KW[group]
        return IntentSpec(name=name, agent=AgentId.FINANCE, tool=tool, keywords=words, extract=fn,
                          examples=examples, priority=priority)  # fmt: skip

    return [
        spec("finance.set_budget", "finance.set_budget", "set_budget", set_budget,
             ("set my food budget to 8000", "khane ka budget 5 hazaar set karo", "खाने का बजट 5000 रखो"), 5),
        spec("finance.recategorize", "finance.recategorize", "recategorize", recategorize,
             ("move the second one to food", "doosra wala khana mein daal do", "दूसरा वाला खाना में डालो"), 5),
        spec("finance.merchant_report", "finance.merchant_report", "merchant", merchant,
             ("how much did I spend on Swiggy last month", "pichhle mahine Zomato pe kitna kharch"), 3),
        spec("finance.category_breakdown", "finance.category_breakdown", "breakdown", breakdown,
             ("category wise spending last month", "पिछले महीने का श्रेणी के हिसाब से खर्च"), 2),
        spec("finance.transactions_search", "finance.transactions_search", "transactions", transactions,
             ("show my transactions this week", "is hafte ke transactions dikhao", "इस हफ़्ते के लेन-देन दिखाओ"), 2),
        spec("finance.recurring", "finance.recurring", "recurring", recurring,
             ("what subscriptions do I have", "meri subscriptions batao", "मेरी सदस्यता दिखाओ"), 2),
        spec("finance.cashflow_forecast", "finance.cashflow_forecast", "forecast", forecast,
             ("cash flow forecast for next month", "agle mahine kitna kharch hoga", "अगले महीने का अनुमान"), 2),
        spec("finance.budget_status", "finance.budget_status", "budget", budget,
             ("how is my budget", "budget kitna bacha hai", "मेरा बजट कैसा है"), 1),
        spec("finance.income_expense", "finance.income_expense", "income", income,
             ("income vs expenses this year", "is saal kitni kamai hui", "इस साल की आय"), 1),
        spec("finance.spending_summary", "finance.spending_summary", "spending", spending,
             ("how much did I spend last month", "pichhle mahine kitna kharch hua", "पिछले महीने कितना खर्च हुआ"), 0),
    ]  # fmt: skip
