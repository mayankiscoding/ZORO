from __future__ import annotations

from datetime import date
from typing import Any

import pytest

from app.finance.categories import CategoryConfigSource
from app.finance.intents import build_intents, parse_amount_words, parse_ordinal, parse_period
from app.finance.plugin import categories_path
from app.tools.intents import IntentContext, IntentRegistry
from tests.finance.conftest import NOW

TODAY = date(2026, 11, 13)


@pytest.fixture(scope="module")
def intents() -> IntentRegistry:
    registry = IntentRegistry()
    for spec in build_intents(CategoryConfigSource(categories_path(None))):
        registry.register(spec)
    return registry


def route(registry: IntentRegistry, text: str, lang: str, **extra: Any) -> tuple[str, dict[str, Any]] | None:
    ctx = IntentContext(lang=lang, now=NOW, **extra)
    for spec in registry.all():
        slots = spec.extract(text, ctx)
        if slots is not None:
            return spec.name, slots
    return None


@pytest.mark.parametrize(
    ("text", "key"),
    [
        ("how much did I spend last month", "last_month"),
        ("pichhle mahine kitna kharch hua", "last_month"),
        ("पिछले महीने कितना खर्च हुआ", "last_month"),
        ("spending this year", "this_year"),
        ("is saal ka kharcha", "this_year"),
        ("इस साल का खर्च", "this_year"),
        ("this month", "this_month"),
        ("इस महीने", "this_month"),
        ("last year", "last_year"),
        ("pichle saal", "last_year"),
        ("last 45 days", "last_45_days"),
        ("pichhle 7 din", "last_7_days"),
        ("पिछले ३० दिनों", "last_30_days"),
        ("in October", "2026-10"),
        ("december", "2025-12"),
        ("अक्टूबर में", "2026-10"),
        ("sep 2025", "2025-09"),
        ("in may", "2026-05"),
        ("may I know my spend", None),
        ("2025 ka kharch", "2025"),
        ("last week", "last_week"),
        ("पिछले हफ्ते", "last_week"),
    ],
)
def test_period_parsing(text: str, key: str | None) -> None:
    assert parse_period(text, TODAY) == key


@pytest.mark.parametrize(
    ("text", "lang", "intent", "slots"),
    [
        ("how much did I spend on food last month", "en", "finance.spending_summary",
         {"period": "last_month", "category": "food"}),
        ("pichhle mahine khane pe kitna kharch hua", "hinglish", "finance.spending_summary",
         {"period": "last_month", "category": "food"}),
        ("पिछले महीने खाने पर कितना खर्च हुआ", "hi", "finance.spending_summary",
         {"period": "last_month", "category": "food"}),
        ("how much did I spend", "en", "finance.spending_summary", {"period": "this_month"}),
        ("how much did I spend on Swiggy in October", "en", "finance.merchant_report",
         {"period": "2026-10", "merchant": "Swiggy"}),
        ("is saal zomato pe kitna kharch kiya", "hinglish", "finance.merchant_report",
         {"period": "this_year", "merchant": "Zomato"}),
        ("category wise spending last month", "en", "finance.category_breakdown", {"period": "last_month"}),
        ("पिछले महीने का श्रेणी के हिसाब से खर्च", "hi", "finance.category_breakdown", {"period": "last_month"}),
        ("show my transactions this week", "en", "finance.transactions_search", {"period": "this_week"}),
        ("इस हफ़्ते के लेन-देन दिखाओ", "hi", "finance.transactions_search", {"period": "this_week"}),
        ("what subscriptions do I have", "en", "finance.recurring", {}),
        ("मेरी सदस्यता दिखाओ", "hi", "finance.recurring", {}),
        ("cash flow forecast for the next 60 days", "en", "finance.cashflow_forecast", {"horizon_days": 60}),
        ("agle mahine kitna kharch hoga forecast", "hinglish", "finance.cashflow_forecast", {"horizon_days": 30}),
        ("how is my food budget", "en", "finance.budget_status", {"category": "food"}),
        ("मेरा बजट कैसा है", "hi", "finance.budget_status", {}),
        ("is saal kitni kamai hui", "hinglish", "finance.income_expense", {"period": "this_year"}),
        ("इस साल की आय", "hi", "finance.income_expense", {"period": "this_year"}),
        ("set my food budget to 8,000", "en", "finance.set_budget", {"category": "food", "limit": "8000.00"}),
        ("khane ka budget 5 hazaar set karo", "hinglish", "finance.set_budget",
         {"category": "food", "limit": "5000.00"}),
        ("खाने का बजट 5000 रखो", "hi", "finance.set_budget", {"category": "food", "limit": "5000.00"}),
    ],
)  # fmt: skip
def test_intents_three_languages(
    intents: IntentRegistry, text: str, lang: str, intent: str, slots: dict[str, Any]
) -> None:
    assert route(intents, text, lang) == (intent, slots)


def test_recategorize_needs_a_list_on_screen(intents: IntentRegistry) -> None:
    shown = {"transactions": [{"id": "ftxn_a"}, {"id": "ftxn_b"}]}
    assert route(intents, "move the second one to food", "en", working_sets=shown) == (
        "finance.recategorize", {"position": 2, "category": "food", "apply_to_merchant": False})  # fmt: skip
    assert route(intents, "doosra wala khana mein daal do", "hinglish", working_sets=shown) == (
        "finance.recategorize", {"position": 2, "category": "food", "apply_to_merchant": False})  # fmt: skip
    assert route(intents, "दूसरा वाला खाना में डालो", "hi", working_sets=shown) == (
        "finance.recategorize", {"position": 2, "category": "food", "apply_to_merchant": False})  # fmt: skip
    assert route(intents, "move the second one to food", "en") is None


def test_keywords_cover_three_languages(intents: IntentRegistry) -> None:
    for spec in intents.all():
        assert set(spec.keywords) == {"en", "hi", "hinglish"} and all(spec.keywords.values()), spec.name


def test_amount_and_ordinal_words() -> None:
    assert parse_amount_words("₹2.5k") == "2500.00"
    assert parse_amount_words("2 lakh") == "200000.00"
    assert parse_amount_words("budget") is None
    assert (
        parse_ordinal("teesra wala") == 3
        and parse_ordinal("number 4") == 4
        and parse_ordinal("hello") is None
    )
