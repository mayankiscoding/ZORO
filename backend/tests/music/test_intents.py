"""Intents in English, Hindi (Devanagari) and Hinglish, with slot filling."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import pytest

from app.music.intents import music_intents
from app.plugins import PluginRegistry
from app.tools.intents import LANGUAGES, IntentContext

CTX = IntentContext(lang="en", now=datetime(2026, 11, 13, 10, 0, tzinfo=UTC))
CTX_WITH_RESULTS = IntentContext(
    lang="en",
    now=CTX.now,
    working_sets={"tracks": [{"uri": "spotify:track:T1"}, {"uri": "spotify:track:T2"}]},
)
SPECS = {s.name: s for s in music_intents()}

CASES: list[tuple[str, str, str, dict[str, Any]]] = [
    # (intent, language, utterance, expected slots)
    ("music.play", "en", "play Kesariya", {"query": "kesariya"}),
    ("music.play", "hi", "केसरिया चलाओ", {"query": "केसरिया"}),
    ("music.play", "hinglish", "Kesariya chalao", {"query": "kesariya"}),
    ("music.play", "en", "play Tum Hi Ho on my Mac", {"query": "tum hi ho", "target": "mac"}),
    ("music.play", "en", "play it on my iPhone", {"target": "iphone"}),
    ("music.play", "hi", "केसरिया चलाओ मेरे मैक पर", {"query": "केसरिया", "target": "mac"}),
    ("music.play", "hinglish", "mere mac par Kesariya bajao", {"query": "kesariya", "target": "mac"}),
    ("music.play", "hinglish", "Kesariya iphone par chalao", {"query": "kesariya", "target": "iphone"}),
    ("music.play", "en", "play the song I was listening to yesterday", {"from_history": "yesterday"}),
    ("music.play", "hi", "कल जो गाना सुन रहा था वो चलाओ", {"from_history": "yesterday"}),
    ("music.play", "hinglish", "kal jo gaana sun raha tha wo chalao", {"from_history": "yesterday"}),
    ("music.play", "en", "play the second one", {"ref": 2}),
    ("music.play", "hinglish", "doosra wala chalao", {"ref": 2}),
    ("music.play", "hi", "दूसरा वाला चलाओ", {"ref": 2}),
    ("music.pause", "en", "pause the music", {}),
    ("music.pause", "hi", "गाना बंद करो", {}),
    ("music.pause", "hinglish", "music band karo", {}),
    ("music.pause", "hinglish", "pause karo mac par", {"target": "mac"}),
    ("music.skip", "en", "skip this song", {"direction": "next"}),
    ("music.skip", "hi", "अगला गाना", {"direction": "next"}),
    ("music.skip", "hinglish", "agla gaana lagao", {"direction": "next"}),
    ("music.skip", "en", "previous song", {"direction": "previous"}),
    ("music.skip", "hinglish", "pichla gaana", {"direction": "previous"}),
    ("music.transfer", "en", "move the music to my Mac", {"target": "mac"}),
    ("music.transfer", "hi", "म्यूज़िक मैक पर ले जाओ", {"target": "mac"}),
    ("music.transfer", "hinglish", "music iPhone par shift karo", {"target": "iphone"}),
    ("music.search", "en", "find songs like Tum Hi Ho", {"query": "tum hi ho", "similar_to": True}),
    ("music.search", "hinglish", "Kesariya jaise gaane", {"query": "kesariya", "similar_to": True}),
    ("music.search", "hi", "Tum Hi Ho जैसे गाने", {"query": "tum hi ho", "similar_to": True}),
    ("music.search", "en", "search for the song Apna Bana Le", {"query": "apna bana le"}),
    ("music.recently_played", "en", "what did I listen to yesterday", {"day": "yesterday"}),
    ("music.recently_played", "hi", "मैंने कल क्या सुना था", {"day": "yesterday"}),
    ("music.recently_played", "hinglish", "maine kal kya suna tha", {"day": "yesterday"}),
    ("music.create_playlist", "en", "create a playlist called Road Trip", {"name": "Road Trip"}),
    ("music.create_playlist", "hi", "प्लेलिस्ट बनाओ रोड ट्रिप", {"name": "रोड ट्रिप"}),
    ("music.create_playlist", "hinglish", "Road Trip naam ki playlist banao", {"name": "Road Trip"}),
]


@pytest.mark.parametrize(("intent", "lang", "text", "expected"), CASES)
def test_slots(intent: str, lang: str, text: str, expected: dict[str, Any]) -> None:
    ctx = CTX_WITH_RESULTS if intent == "music.play" else CTX
    got = SPECS[intent].extract(text, ctx)
    assert got == expected, f"{lang}: {text!r}"
    # exactly one music intent claims it
    others = [n for n, s in SPECS.items() if n != intent and s.extract(text, ctx) is not None]
    assert others == [], f"{text!r} also matched {others}"


def test_ordinal_needs_something_to_point_at() -> None:
    assert "ref" not in (SPECS["music.play"].extract("play the second one", CTX) or {})


def test_missing_slots_are_reported() -> None:
    assert SPECS["music.transfer"].extract("transfer the music", CTX) == {"_missing": ["target"]}
    assert SPECS["music.create_playlist"].extract("playlist banao", CTX) == {"_missing": ["name"]}
    assert SPECS["music.play"].extract("play", CTX) == {}


def test_other_domains_are_not_claimed() -> None:
    for text in (
        "send a message to mom",
        "set an alarm for 7am",
        "what is my balance",
        "phone par call karo",
    ):
        assert all(s.extract(text, CTX) is None for s in SPECS.values()), text


def test_registered_with_keywords_in_three_languages(registry: PluginRegistry) -> None:
    tools = {t.name for t in registry.tools}
    intents = registry.intents.all()
    assert {i.name for i in intents} == set(SPECS)
    for spec in intents:
        assert spec.tool in tools
        assert set(spec.keywords) == set(LANGUAGES) and all(spec.keywords[lang] for lang in LANGUAGES)
        assert spec.agent.value == "music" and spec.examples
