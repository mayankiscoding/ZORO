"""Language id, the local intent router and the numeric guard (pure code, no app needed)."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from app.core.types import AgentId
from app.orchestrator.language import detect_language
from app.orchestrator.numeric_guard import invented_numbers, numbers_in_text
from app.orchestrator.router import IntentRouter, split_compound
from app.plugins import PluginRegistry
from app.tools.intents import IntentContext
from tests.orchestrator.toolkit import PRODUCTS, Toolbox


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("How much did I spend this month?", "en"),
        ("मैंने इस महीने कितना खर्च किया?", "hi"),
        ("is mahine kitna kharcha hua", "hinglish"),
        ("kal subah 7 baje alarm lagao", "hinglish"),
        ("मेरा budget कितना है", "hi"),  # Devanagari with an English word is still Hindi
        ("play some music", "en"),
        ("find milk and do it", "en"),  # "do" is not treated as Hindi
        ("", "en"),
        ("12345", "en"),
    ],
)
def test_detect_language(text: str, expected: str) -> None:
    assert detect_language(text) == expected


def test_language_hint_breaks_ties_only() -> None:
    assert detect_language("", "hi") == "hi"
    assert detect_language("kharcha report", "hinglish") == "hinglish"
    assert detect_language("How much did I spend?", "hi") == "en"  # the script of what was said wins
    assert detect_language("खर्च बताओ", "en") == "hi"
    assert detect_language("ok", "klingon") == "en"


def _ctx(lang: str, **kw: object) -> IntentContext:
    return IntentContext(lang=lang, now=datetime.now(UTC), **kw)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("text", "lang"),
    [
        ("how much did I spend last month", "en"),
        ("पिछले महीने कितना खर्च हुआ", "hi"),
        ("pichhle mahine kitna kharcha hua", "hinglish"),
    ],
)
def test_router_matches_each_language(registry: PluginRegistry, box: Toolbox, text: str, lang: str) -> None:
    route = IntentRouter(registry.intents, registry.tools).route(text, _ctx(lang))
    assert route.confident
    assert [step.intent.name for step in route.steps] == ["test.spending"]
    assert route.steps[0].intent.agent is AgentId.FINANCE
    assert route.steps[0].slots == {"month": "2026-10"}


def test_router_compound_and_fallback_to_whole(registry: PluginRegistry, box: Toolbox) -> None:
    router = IntentRouter(registry.intents, registry.tools)
    both = router.route("how much did I spend and find some songs", _ctx("en"))
    assert [step.intent.name for step in both.steps] == ["test.spending", "test.tracks"]
    hinglish = router.route("kharcha batao aur gaane sunao", _ctx("hinglish"))
    assert [step.intent.name for step in hinglish.steps] == ["test.spending", "test.tracks"]
    hindi = router.route("खर्च बताओ और गाने सुनाओ", _ctx("hi"))
    assert [step.intent.name for step in hindi.steps] == ["test.spending", "test.tracks"]
    # "bread" alone routes nowhere, so the request is not split.
    whole = router.route("search for milk and bread", _ctx("en"))
    assert [step.intent.name for step in whole.steps] == ["test.products"]
    assert split_compound("a and b; c aur d और e") == ["a", "b", "c", "d", "e"]


def test_router_low_confidence_and_no_match(registry: PluginRegistry, box: Toolbox) -> None:
    router = IntentRouter(registry.intents, registry.tools)
    nothing = router.route("tell me a joke", _ctx("en"))
    assert not nothing.confident and nothing.best is None
    # A Hindi keyword inside an English sentence counts less: below the confidence bar.
    weak = router.route("what about my खर्च", _ctx("en"))
    assert not weak.confident and weak.best is not None and weak.best.intent.name == "test.spending"
    # The extractor says "not this intent" when there is no list to pick from.
    assert not router.route("add the second one", _ctx("en")).confident


def test_router_uses_working_sets_and_follow_up_bonus(registry: PluginRegistry, box: Toolbox) -> None:
    router = IntentRouter(registry.intents, registry.tools)
    ctx = _ctx("hinglish", working_sets={"products": PRODUCTS}, last_agent=AgentId.SHOPPING)
    route = router.route("doosra wala add karo", ctx)
    assert route.confident
    assert route.steps[0].slots == {"ref": "p2", "name": "Mother Dairy Toned Milk 1 L"}
    plain = router.route("doosra wala add karo", _ctx("hinglish", working_sets={"products": PRODUCTS}))
    assert route.confidence >= plain.confidence


def test_numbers_are_normalised() -> None:
    assert numbers_in_text("₹1,23,456.50 और १२३४ रुपये, 12.0%") == {"123456.5", "1234", "12"}
    assert numbers_in_text("Rs 1,234.00 on 2026-10-03") == {"1234", "2026", "10", "3"}


def test_guard_accepts_sourced_and_rejects_invented_numbers() -> None:
    sources = [{"total": "12450.50", "transactions": 14, "nested": [{"when": "2026-10"}]}]
    assert invented_numbers("आपने ₹12,450.5 खर्च किए, १४ लेन-देन में।", sources) == []
    assert invented_numbers("You spent ₹12,450.50 in 14 transactions in 2026-10.", sources) == []
    assert invented_numbers("You spent ₹12,500 in 14 transactions.", sources) == ["12500"]
    assert invented_numbers("That is 20% more than last month.", sources) == ["20"]
    assert invented_numbers("No figures here.", []) == []
    assert invented_numbers("True is not 1.", [{"flag": True}]) == ["1"]
