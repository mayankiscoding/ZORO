"""Automation intents: list the routines, run one by name or from the list just shown."""

from __future__ import annotations

import re
from typing import Any

from app.core.types import AgentId
from app.tools.intents import IntentContext, IntentSpec

_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")
_ROUTINE = ("routine", "routines", "रूटीन", "रुटीन", "रूटीन्स")
_RUN_EN = r"(?:run|start|trigger|execute|launch|do)"
_RUN_HI = r"(?:chalao|chalana|chala do|chala de|shuru karo|shuru kar do|run karo|चलाओ|चलाना|चला दो|शुरू करो|शुरू कर दो|चलाइए)"
_ORDINALS = {
    1: ("first", "1st", "pehla", "pehle", "pahla", "पहला", "पहले"),
    2: ("second", "2nd", "doosra", "dusra", "doosre", "दूसरा", "दूसरे"),
    3: ("third", "3rd", "teesra", "tisra", "तीसरा", "तीसरे"),
    4: ("fourth", "4th", "chautha", "चौथा"),
    5: ("fifth", "5th", "paanchva", "पाँचवा", "पांचवा"),
}
KEYWORDS = {
    "en": ("routine", "routines", "run my routine", "start my routine"),
    "hi": ("रूटीन", "रुटीन", "रूटीन चलाओ"),
    "hinglish": ("routine", "routines", "routine chalao", "routine shuru karo"),
}
_FILLER = ("the", "my", "a", "meri", "mera", "mere", "apna", "वाला", "wala", "मेरा", "मेरी", "मेरे")


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[?!.,।]", " ", text.lower().translate(_DIGITS))).strip()


def _has_routine(text: str) -> bool:
    return any(w in text.split() or (not w.isascii() and w in text) for w in _ROUTINE)


def _clean(name: str) -> str:
    words = [w for w in name.split() if w not in _FILLER]
    return " ".join(words).strip()


def _ordinal(text: str) -> int | None:
    for n, words in _ORDINALS.items():
        if any((f" {w} " in f" {text} ") for w in words):
            return n
    return None


def _wants_run(text: str) -> bool:
    return bool(re.search(rf"\b{_RUN_EN}\b", text)) or bool(re.search(_RUN_HI, text))


def extract_list(utterance: str, ctx: IntentContext) -> dict[str, Any] | None:
    text = _norm(utterance)
    if not _has_routine(text) or _wants_run(text):
        return None
    return {}


def extract_run(utterance: str, ctx: IntentContext) -> dict[str, Any] | None:
    text = _norm(utterance)
    if not _wants_run(text):
        return None
    shown = ctx.working_sets.get("routines", ())
    n = _ordinal(text)
    if (
        n is not None
        and shown
        and n <= len(shown)
        and (_has_routine(text) or "one" in text.split() or "wala" in text.split() or "वाला" in text)
    ):
        return {"routine": str(shown[n - 1]["id"])}
    if not _has_routine(text):
        return None
    m = (
        re.search(rf"\b{_RUN_EN}\s+(?P<n>.+?)\s+(?:routine|रूटीन|रुटीन)\b", text)
        or re.search(rf"(?P<n>.+?)\s+(?:routine|रूटीन|रुटीन)\s+{_RUN_HI}", text)
        or re.search(rf"\b{_RUN_EN}\s+(?:routine|रूटीन|रुटीन)\s+(?P<n>.+)$", text)
        or re.search(rf"(?:routine|रूटीन|रुटीन)\s+(?P<n>.+?)\s+{_RUN_HI}", text)
    )
    if m is None:
        return None
    name = _clean(m.group("n"))
    name = re.sub(rf"^{_RUN_EN}\s+", "", name)
    return {"routine": name} if name else None


def build_intents() -> list[IntentSpec]:
    a = AgentId.AUTOMATION
    return [
        IntentSpec(
            name="automation.list_routines",
            agent=a,
            tool="automation.list_routines",
            keywords=KEYWORDS,
            extract=extract_list,
            priority=3,
            examples=("what are my routines", "mere routines dikhao", "मेरे रूटीन दिखाओ"),
        ),
        IntentSpec(
            name="automation.run_routine",
            agent=a,
            tool="automation.run_routine",
            keywords=KEYWORDS,
            extract=extract_run,
            priority=5,
            examples=("run my morning routine", "morning routine chalao", "सुबह का रूटीन चलाओ"),
        ),
    ]
