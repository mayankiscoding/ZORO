"""Resolve "the second one" / "doosra wala" / "दूसरा वाला" / "this one" / "add two more packets"
against the products last shown in this conversation (working set "products").

Deterministic. Anything ambiguous returns a clarification with the options, never a guess.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Mapping, Sequence
from typing import Any, Literal

from pydantic import Field

from app.shopping.normalize import parse_pack
from app.shopping.types import SModel

WORKING_SET = "products"
LAST = -1

_ORDINALS: dict[str, int] = {
    # en
    "first": 0,
    "1st": 0,
    "second": 1,
    "2nd": 1,
    "third": 2,
    "3rd": 2,
    "fourth": 3,
    "4th": 3,
    "fifth": 4,
    "5th": 4,
    "sixth": 5,
    "6th": 5,
    "last": LAST,
    # hinglish (romanised)
    "pehla": 0,
    "pehli": 0,
    "pehle": 0,
    "pahla": 0,
    "pahli": 0,
    "doosra": 1,
    "dusra": 1,
    "doosri": 1,
    "dusri": 1,
    "doosre": 1,
    "dusre": 1,
    "teesra": 2,
    "tisra": 2,
    "teesri": 2,
    "tisri": 2,
    "teesre": 2,
    "chautha": 3,
    "chauthi": 3,
    "chauthe": 3,
    "paanchva": 4,
    "panchva": 4,
    "paanchvi": 4,
    "aakhri": LAST,
    "akhri": LAST,
    # hi (Devanagari)
    "पहला": 0,
    "पहली": 0,
    "पहले": 0,
    "दूसरा": 1,
    "दूसरी": 1,
    "दूसरे": 1,
    "तीसरा": 2,
    "तीसरी": 2,
    "तीसरे": 2,
    "चौथा": 3,
    "चौथी": 3,
    "चौथे": 3,
    "पांचवां": 4,
    "पाँचवाँ": 4,
    "पांचवीं": 4,
    "आखिरी": LAST,
    "आख़िरी": LAST,
    "अंतिम": LAST,
}
_NUMBER_PREFIX = re.compile(r"\b(?:number|no\.?|option|item|#)\s*(\d{1,2})\b", re.I)
_DEICTIC = re.compile(
    r"\b(this|that|it|this one|that one|ye|yeh|yahi|isko|ise|usko|wo|woh)\b|यह|ये|इसे|इसको|यही|वह|उसे", re.I
)
_NUMBERS: dict[str, int] = {
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "ek": 1,
    "teen": 3,
    "char": 4,
    "chaar": 4,
    "paanch": 5,
    "panch": 5,
    "chhe": 6,
    "saat": 7,
    "aath": 8,
    "nau": 9,
    "das": 10,
    "एक": 1,
    "दो": 2,
    "तीन": 3,
    "चार": 4,
    "पांच": 5,
    "पाँच": 5,
    "छह": 6,
    "सात": 7,
    "आठ": 8,
    "नौ": 9,
    "दस": 10,
}
_REF_ONE = re.compile(
    r"\b(?:this|that|the|which|first|second|third|fourth|fifth|sixth|last|cheaper|cheapest|other)\s+one\b",
    re.I,
)
_MORE = r"(?:more|extra|aur|और|zyada)"
_UNIT = r"(?:packets?|packs?|pcs|pieces?|units?|bottles?|boxes|box|bags?|packet|पैकेट|डिब्बे|बोतल)"
_NUM_WORD = "|".join(sorted(map(re.escape, _NUMBERS), key=len, reverse=True))
_QTY = re.compile(
    rf"(?<![\w.])(?P<n>\d{{1,2}}|{_NUM_WORD}|do)\s*(?P<more>{_MORE})?\s*(?P<unit>{_UNIT})?(?![\w])", re.I
)


def _norm(text: str) -> str:
    return unicodedata.normalize("NFC", text).lower().translate(str.maketrans("०१२३४५६७८९", "0123456789"))


class Clarification(SModel):
    question: str
    options: list[dict[str, Any]] = Field(default_factory=list)


class ReferenceResolution(SModel):
    status: Literal["resolved", "ambiguous", "out_of_range", "none"]
    index: int | None = None
    item: dict[str, Any] | None = None
    clarification: Clarification | None = None


class QuantityRequest(SModel):
    quantity: int | None = None
    mode: Literal["set", "add"] = "set"
    variant_hint: str | None = None


def _ordinals(text: str) -> set[int]:
    found = {idx for word, idx in _ORDINALS.items() if re.search(rf"(?<!\w){re.escape(word)}(?!\w)", text)}
    found |= {int(m.group(1)) - 1 for m in _NUMBER_PREFIX.finditer(text)}
    return found


def _options(items: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    return [
        {"index": i + 1, "ref": it.get("ref"), "label": it.get("label") or it.get("name")}
        for i, it in enumerate(items)
    ]


def _question(lang: str) -> str:
    return {
        "hi": "आप कौन सा वाला चाहते हैं?",
        "hinglish": "Aap kaun sa wala chahte hain?",
    }.get(lang, "Which one do you mean?")


def resolve_reference(
    utterance: str,
    items: Sequence[Mapping[str, Any]],
    *,
    lang: str = "en",
    selected_ref: str | None = None,
    implicit: bool = False,
) -> ReferenceResolution:
    """`implicit=True` treats an utterance with no reference words ("add two more packets") as "this one"."""
    text = _norm(utterance)
    ordinals = _ordinals(text)

    def ask(status: Literal["ambiguous", "out_of_range"]) -> ReferenceResolution:
        return ReferenceResolution(
            status=status, clarification=Clarification(question=_question(lang), options=_options(items))
        )

    if not items:
        return ReferenceResolution(status="none") if not ordinals else ask("out_of_range")
    if len(ordinals) > 1:
        return ask("ambiguous")
    if ordinals:
        idx = next(iter(ordinals))
        idx = len(items) - 1 if idx == LAST else idx
        if not 0 <= idx < len(items):
            return ask("out_of_range")
        return ReferenceResolution(status="resolved", index=idx, item=dict(items[idx]))
    if _DEICTIC.search(text) or implicit:
        if selected_ref is not None:
            for i, it in enumerate(items):
                if it.get("ref") == selected_ref:
                    return ReferenceResolution(status="resolved", index=i, item=dict(it))
        if len(items) == 1:
            return ReferenceResolution(status="resolved", index=0, item=dict(items[0]))
        return ask("ambiguous")
    return ReferenceResolution(status="none")


def parse_quantity(utterance: str) -> QuantityRequest:
    """ "add two more packets" -> add 2; "teen packet" -> set 3; "1 kg wala" -> variant hint, no quantity."""
    text = _norm(utterance)
    pack = parse_pack(text)
    hint = pack.label if pack is not None else None
    stripped = text
    if pack is not None:
        stripped = re.sub(r"\d+(?:\.\d+)?\s*(?:kg|g|gm|gms|ml|l|ltr|litre|liter)s?\b", " ", stripped)
    for word in [w for w in _ORDINALS if w[0].isdigit()]:
        stripped = stripped.replace(word, " ")
    stripped = _NUMBER_PREFIX.sub(" ", stripped)
    stripped = _REF_ONE.sub(" ", stripped)  # "the second one" / "this one" is not a quantity
    for match in _QTY.finditer(stripped):
        raw = match.group("n")
        if raw == "do" and not (match.group("more") or match.group("unit")):
            continue  # English "do", not Hinglish "two"
        value = int(raw) if raw.isdigit() else _NUMBERS.get(raw, 2 if raw == "do" else 0)
        if value <= 0:
            continue
        mode: Literal["set", "add"] = "add" if match.group("more") else "set"
        return QuantityRequest(quantity=value, mode=mode, variant_hint=_hint(hint))
    return QuantityRequest(variant_hint=_hint(hint))


def _hint(label: str | None) -> str | None:
    if label is None:
        return None
    pack = parse_pack(label)
    if pack is None:
        return None
    match = re.search(r"\d+(?:\.\d+)?\s*(?:kg|g|gm|gms|ml|l|ltr|litre|liter)s?\b", label)
    return match.group(0) if match else None
