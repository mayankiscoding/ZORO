from __future__ import annotations

import pytest

from app.shopping.references import parse_quantity, resolve_reference

ITEMS = [
    {"ref": "s:p1", "label": "Aashirvaad"},
    {"ref": "s:p2", "label": "Pillsbury"},
    {"ref": "s:p3", "label": "Amul"},
]


@pytest.mark.parametrize(
    ("utterance", "lang", "ref"),
    [
        ("add the second one", "en", "s:p2"),
        ("the 1st one please", "en", "s:p1"),
        ("number 3", "en", "s:p3"),
        ("add the last one", "en", "s:p3"),
        ("doosra wala add karo", "hinglish", "s:p2"),
        ("dusri wali", "hinglish", "s:p2"),
        ("teesra wala", "hinglish", "s:p3"),
        ("pehla wala daal do", "hinglish", "s:p1"),
        ("दूसरा वाला जोड़ो", "hi", "s:p2"),
        ("पहला वाला", "hi", "s:p1"),
        ("आखिरी वाला", "hi", "s:p3"),
        ("option २", "hi", "s:p2"),
    ],
)
def test_ordinals_in_three_languages(utterance: str, lang: str, ref: str) -> None:
    result = resolve_reference(utterance, ITEMS, lang=lang)
    assert result.status == "resolved" and result.item is not None and result.item["ref"] == ref


@pytest.mark.parametrize(
    ("utterance", "lang", "question"),
    [
        ("this one", "en", "Which one do you mean?"),
        ("ye wala", "hinglish", "Aap kaun sa wala chahte hain?"),
        ("यह वाला", "hi", "आप कौन सा वाला चाहते हैं?"),
        ("the first or the second", "en", "Which one do you mean?"),
    ],
)
def test_ambiguity_asks_never_guesses(utterance: str, lang: str, question: str) -> None:
    result = resolve_reference(utterance, ITEMS, lang=lang)
    assert result.status == "ambiguous" and result.item is None
    assert result.clarification is not None and result.clarification.question == question
    assert [o["ref"] for o in result.clarification.options] == ["s:p1", "s:p2", "s:p3"]


def test_this_one_resolves_with_a_selection_or_a_single_item() -> None:
    assert resolve_reference("this one", ITEMS, selected_ref="s:p3").item == ITEMS[2]
    assert resolve_reference("isko", ITEMS[:1], lang="hinglish").item == ITEMS[0]
    assert resolve_reference("add two more packets", ITEMS[:1], implicit=True).item == ITEMS[0]
    assert resolve_reference("add two more packets", ITEMS, implicit=True).status == "ambiguous"
    assert resolve_reference("hello there", ITEMS).status == "none"


def test_out_of_range_and_empty_working_set() -> None:
    assert resolve_reference("the fifth one", ITEMS).status == "out_of_range"
    assert resolve_reference("the second one", []).status == "out_of_range"
    assert resolve_reference("this one", []).status == "none"


@pytest.mark.parametrize(
    ("utterance", "quantity", "mode", "hint"),
    [
        ("add two more packets", 2, "add", None),
        ("2 more", 2, "add", None),
        ("do aur packet", 2, "add", None),
        ("दो और पैकेट", 2, "add", None),
        ("teen packet", 3, "set", None),
        ("add the second one", None, "set", None),
        ("do it", None, "set", None),
        ("the 1 kg one", None, "set", "1 kg"),
        ("add 3 of the 500ml", 3, "set", "500ml"),
    ],
)
def test_quantity_parsing(utterance: str, quantity: int | None, mode: str, hint: str | None) -> None:
    parsed = parse_quantity(utterance)
    assert (parsed.quantity, parsed.mode, parsed.variant_hint) == (quantity, mode, hint)
