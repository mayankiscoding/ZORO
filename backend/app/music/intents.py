"""Music intents with deterministic slot filling (English, Hindi, Hinglish).

Extractors return tool arguments. Keys starting with "_" are hints for the orchestrator (`_missing`:
required slots not found) and are ignored by the tools' input models.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from typing import Any

from app.core.types import AgentId
from app.tools.intents import IntentContext, IntentSpec

Slots = dict[str, Any]
_EDGE = r"[\s.,!?;:'\"()]"
_URI = re.compile(r"spotify:(?:track|album|playlist|artist|episode):[A-Za-z0-9]+")


def norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower().replace("’", "'")).strip()


def has(text: str, words: Iterable[str]) -> bool:
    """Whole-word / whole-phrase test that also works for Devanagari (where \\b misbehaves)."""
    t = f" {norm(text)} "
    return any(re.search(rf"(?<={_EDGE}){re.escape(w)}(?={_EDGE})", t) for w in words)


def strip_words(text: str, words: Iterable[str]) -> str:
    """Remove whole words / phrases (longest first), then tidy."""
    t = f" {norm(text)} "
    for w in sorted(set(words), key=len, reverse=True):
        t = re.sub(rf"(?<={_EDGE}){re.escape(w)}(?={_EDGE})", " ", t)
    t = re.sub(r"[.,!?;:]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


# ---------------------------------------------------------------- vocabulary

PLAY = ("play", "put on", "listen to", "start", "resume", "chalao", "chala do", "chalado", "bajao", "baja do",
        "play karo", "play kar do", "sunao", "suna do", "lagao", "laga do", "chalu karo", "चलाओ", "चला दो",
        "बजाओ", "बजा दो", "सुनाओ", "सुना दो", "लगाओ", "लगा दो", "प्ले", "चालू करो", "चालू कर दो")  # fmt: skip
PAUSE_STRONG = ("pause", "pause karo", "roko", "rok do", "रोको", "रोक दो", "पॉज़", "पॉज")
PAUSE_WEAK = ("stop the music", "stop music", "stop playing", "stop the song", "band karo", "band kar do",
              "बंद करो", "बंद कर दो", "रुको")  # fmt: skip
PAUSE = (*PAUSE_STRONG, *PAUSE_WEAK)
NEXT = ("next song", "next track", "next one", "skip", "skip this", "agla gaana", "agla gana", "agla wala",
        "next gaana", "next karo", "skip karo", "अगला गाना", "अगला गाने", "अगला", "स्किप", "नेक्स्ट")  # fmt: skip
PREV = ("previous song", "previous track", "go back", "pichla gaana", "pichla gana", "pichla wala",
        "previous gaana", "पिछला गाना", "पिछला", "प्रीवियस")  # fmt: skip
TRANSFER = ("move", "switch", "transfer", "shift", "send", "continue", "shift karo", "le jao", "le chalo",
            "le ja", "ट्रांसफर", "शिफ्ट", "ले जाओ", "ले चलो", "बदलो")  # fmt: skip
MUSICY = ("music", "playback", "song", "songs", "gaana", "gaane", "gana", "track", "म्यूज़िक", "म्यूजिक",
          "संगीत", "गाना", "गाने", "प्लेबैक")  # fmt: skip
MAC = ("mac", "macbook", "my mac", "मैक", "मेरे मैक", "मैकबुक")
PHONE = ("iphone", "my iphone", "phone", "my phone", "आईफोन", "आईफ़ोन", "फोन", "फ़ोन", "मेरे फोन")
YESTERDAY = ("yesterday", "kal", "कल")
TODAY = ("today", "aaj", "आज")
LISTENED = ("listening", "listened", "was listening", "listening to", "sun raha", "sun rahi", "sunta", "suna",
            "sunte", "सुन रहा", "सुन रही", "सुनता", "सुना", "सुनते")  # fmt: skip
SIMILAR = ("like", "similar to", "similar", "jaise", "jaisa", "jaisi", "milte julte", "जैसे", "जैसा", "मिलते-जुलते")
FILLER = ("it", "this", "that", "please", "can you", "could you", "for me", "ek", "ज़रा", "zara", "jara", "mujhe", "मुझे", "kuch", "कुछ",
          "some", "the", "a", "an", "song", "songs", "music", "gaana", "gaane", "gana", "गाना", "गाने", "wala",
          "wali", "वाला", "वाली", "to", "ko", "को", "on spotify", "on apple music", "spotify", "apple music",
          "par", "पर", "mere", "मेरे", "my", "on", "me", "पे", "pe")  # fmt: skip

_ORDINALS: dict[str, int] = {
    "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "fifth": 5,
    "5th": 5, "pehla": 1, "pehle": 1, "पहला": 1, "पहले": 1, "doosra": 2, "dusra": 2, "doosre": 2, "दूसरा": 2,
    "दूसरे": 2, "teesra": 3, "tisra": 3, "तीसरा": 3, "chautha": 4, "चौथा": 4, "paanchva": 5, "panchva": 5,
    "पाँचवाँ": 5, "पांचवां": 5,
}  # fmt: skip


_RECENT = ("what did i listen", "what was i listening", "what have i listened", "recently played", "listening history",
           "play history", "maine kya suna", "maine kya sune", "kya suna tha", "kya sun raha", "recently suna",
           "मैंने क्या सुना", "क्या सुना था", "क्या सुन रहा", "हाल ही में सुने", "सुनने का इतिहास")  # fmt: skip


def target_of(text: str) -> tuple[str | None, list[str]]:
    """("mac" | "iphone" | None, words to strip). Needs a place word so "phone" alone is not a target."""
    t = norm(text)
    place = re.search(rf"(?<={_EDGE})(on|par|पर|पे|pe|to|ko|को|on to)(?={_EDGE})", f" {t} ")
    if has(t, MAC) and place:
        return "mac", list(MAC)
    if has(t, PHONE) and place:
        return "iphone", list(PHONE)
    return None, []


def _ordinal(text: str) -> int | None:
    t = norm(text)
    for word, n in _ORDINALS.items():
        if has(t, (word,)):
            return n
    match = re.search(rf"(?<={_EDGE})(?:number|no\.?|#|नंबर)\s*(\d)(?={_EDGE})", f" {t} ")
    return int(match.group(1)) if match else None


# ---------------------------------------------------------------- extractors


def _with_target(slots: Slots, text: str) -> Slots:
    target, _ = target_of(text)
    if target:
        slots["target"] = target
    return slots


def extract_play(text: str, ctx: IntentContext) -> Slots | None:
    if not has(text, PLAY) or has(text, PAUSE) or has(text, NEXT) or has(text, PREV):
        return None
    if any(p in norm(text) for p in _RECENT):
        return None  # "what did I listen to yesterday" is a question, not a request to play
    if has(text, TRANSFER) and has(text, MUSICY) and not _URI.search(text):
        return None  # "move the music to my Mac" is a transfer
    slots: Slots = {}
    uri = _URI.search(text)
    if uri:
        slots["uri"] = uri.group(0)
        return _with_target(slots, text)
    if has(text, YESTERDAY) and has(text, LISTENED):
        slots["from_history"] = "yesterday"
        return _with_target(slots, text)
    if has(text, TODAY) and has(text, LISTENED):
        slots["from_history"] = "today"
        return _with_target(slots, text)
    ref = _ordinal(text)
    if ref is not None and ctx.working_sets.get("tracks"):
        slots["ref"] = ref
        return _with_target(slots, text)
    if has(text, LISTENED):  # "the song I was listening to"
        slots["from_history"] = "last"
        return _with_target(slots, text)
    _, target_words = target_of(text)
    query = strip_words(text, (*PLAY, *FILLER, *target_words, *MUSICY))
    if query:
        slots["query"] = query
    return _with_target(slots, text)


def extract_pause(text: str, ctx: IntentContext) -> Slots | None:
    if not (has(text, PAUSE_STRONG) or (has(text, PAUSE_WEAK) and has(text, MUSICY))):
        return None  # "band karo" alone could be anything: it needs a music word
    return _with_target({}, text)


def extract_skip(text: str, ctx: IntentContext) -> Slots | None:
    previous = has(text, PREV)
    if not (has(text, NEXT) or previous):
        return None
    explicit = ("skip", "next", "स्किप", "नेक्स्ट", "agla", "अगला", "pichla", "पिछला", "previous")
    if has(text, PLAY) and not has(text, explicit):
        return None
    return _with_target({"direction": "previous" if previous else "next"}, text)


def extract_transfer(text: str, ctx: IntentContext) -> Slots | None:
    if not (has(text, TRANSFER) and has(text, MUSICY)):
        return None
    target, _ = target_of(text)
    return {"target": target} if target else {"_missing": ["target"]}


def extract_search(text: str, ctx: IntentContext) -> Slots | None:
    t = norm(text)
    similar = has(t, SIMILAR)
    searching = has(
        t,
        ("search", "find", "look for", "look up", "dhundo", "dhoondo", "khojo", "सर्च", "खोजो", "ढूंढो", "ढूँढो"),
    )
    if has(t, PLAY) or not (searching or similar) or not has(t, (*MUSICY, "similar")):
        return None
    if similar:
        before = re.split(rf"(?<={_EDGE})(?:jaise|jaisa|jaisi|जैसे|जैसा|जैसी)(?={_EDGE})", f" {t} ", maxsplit=1)
        after = re.split(rf"(?<={_EDGE})(?:like|similar to|similar)(?={_EDGE})", f" {t} ", maxsplit=1)
        raw = after[1] if len(after) > 1 else before[0]
        query = strip_words(
            raw,
            (*FILLER, *MUSICY, "find", "search", "for", "look for", "me", "dhundo", "khojo", "karo", "बताओ"),
        )
        return {"query": query, "similar_to": True} if query else {"_missing": ["query"]}
    query = strip_words(
        t,
        (
            *FILLER,
            *MUSICY,
            "search",
            "find",
            "look for",
            "look up",
            "for",
            "dhundo",
            "dhoondo",
            "khojo",
            "karo",
            "सर्च",
            "खोजो",
            "ढूंढो",
            "ढूँढो",
            "करो",
        ),
    )
    return {"query": query} if query else {"_missing": ["query"]}


def extract_recent(text: str, ctx: IntentContext) -> Slots | None:
    if not any(p in norm(text) for p in _RECENT):
        return None
    if has(text, YESTERDAY):
        return {"day": "yesterday"}
    if has(text, TODAY):
        return {"day": "today"}
    return {}


_PLAYLIST = ("playlist", "प्लेलिस्ट", "प्लेलिस्ट")
_MAKE = (
    "create",
    "make",
    "new",
    "add",
    "banao",
    "bana do",
    "bana de",
    "naya",
    "nayi",
    "बनाओ",
    "बना दो",
    "नई",
    "नया",
)
_NAME_BEFORE = re.compile(r"(.+?)\s+(?:naam ki|naam se|नाम की|नाम से|named)\s+(?:playlist|प्लेलिस्ट)")
_NAMED = re.compile(r"(?:called|named|titled|name it|naam|नाम)\s+(.+)")
_THESE = (
    "these songs",
    "these",
    "this list",
    "ye gaane",
    "ye wale",
    "इन गानों",
    "ये गाने",
    "इन्हें",
    "these tracks",
)


def extract_playlist(text: str, ctx: IntentContext) -> Slots | None:
    if not has(text, _PLAYLIST) or not has(text, _MAKE):
        return None
    t = norm(text)
    slots: Slots = {}
    if has(t, _THESE) and ctx.working_sets.get("tracks"):
        slots["use_last_search"] = True
    m = _NAME_BEFORE.search(t) or _NAMED.search(t)
    name = m.group(1) if m else t
    name = strip_words(
        name,
        (
            *_PLAYLIST,
            *_MAKE,
            *_THESE,
            *FILLER,
            "with",
            "called",
            "named",
            "naam",
            "नाम",
            "ki",
            "की",
            "karo",
            "करो",
            "my",
            "new",
            "and",
            "add",
        ),
    )
    if not name:
        slots["_missing"] = ["name"]
    else:
        slots["name"] = name.title() if name.isascii() and name == name.lower() else name
    return slots


# ---------------------------------------------------------------- specs

_M = AgentId.MUSIC


def music_intents() -> list[IntentSpec]:
    return [
        IntentSpec(
            "music.play",
            _M,
            "music.play",
            {
                "en": ["play", "put on", "listen to", "resume music", "start the music"],
                "hi": ["चलाओ", "चला दो", "बजाओ", "सुनाओ", "गाना चलाओ", "प्ले"],
                "hinglish": ["chalao", "chala do", "bajao", "play karo", "sunao", "gaana laga do", "lagao"],
            },
            extract_play,
            examples=(
                "play Kesariya",
                "play it on my Mac",
                "play the song I was listening to yesterday",
                "कल जो गाना सुन रहा था वो चलाओ",
                "kal jo gaana sun raha tha wo chalao",
            ),
        ),
        IntentSpec(
            "music.pause",
            _M,
            "music.pause",
            {
                "en": ["pause", "stop the music", "stop playing"],
                "hi": ["रोको", "म्यूज़िक बंद करो", "गाना बंद करो", "रोक दो"],
                "hinglish": ["pause karo", "gaana band karo", "music band karo", "roko"],
            },
            extract_pause,
            examples=("pause the music", "गाना बंद करो", "music band karo"),
        ),
        IntentSpec(
            "music.skip",
            _M,
            "music.skip",
            {
                "en": ["next song", "skip", "next track", "previous song", "go back"],
                "hi": ["अगला गाना", "अगला", "स्किप", "पिछला गाना"],
                "hinglish": ["agla gaana", "next gaana", "skip karo", "pichla gaana"],
            },
            extract_skip,
            examples=("skip this song", "अगला गाना", "pichla gaana lagao"),
        ),
        IntentSpec(
            "music.transfer",
            _M,
            "music.transfer",
            {
                "en": ["move the music to", "switch playback to", "transfer playback", "continue on my"],
                "hi": ["म्यूज़िक ट्रांसफर करो", "गाना मैक पर ले जाओ", "म्यूज़िक शिफ्ट करो"],
                "hinglish": ["music shift karo", "gaana mac par le jao", "playback transfer karo"],
            },
            extract_transfer,
            priority=2,
            examples=("move the music to my Mac", "म्यूज़िक मैक पर ले जाओ", "music iPhone par shift karo"),
        ),
        IntentSpec(
            "music.search",
            _M,
            "music.search",
            {
                "en": ["find songs like", "similar songs to", "search for the song", "songs similar to"],
                "hi": ["जैसे गाने", "गाना खोजो", "मिलते-जुलते गाने"],
                "hinglish": ["jaise gaane", "similar gaane", "gaana dhundo", "song search karo"],
            },
            extract_search,
            examples=("find songs like Tum Hi Ho", "Kesariya jaise gaane", "Tum Hi Ho जैसे गाने"),
        ),
        IntentSpec(
            "music.recently_played",
            _M,
            "music.recently_played",
            {
                "en": ["what did I listen to", "recently played", "my listening history"],
                "hi": ["मैंने क्या सुना", "हाल ही में सुने", "सुनने का इतिहास"],
                "hinglish": ["maine kya suna", "recently played", "kal kya suna tha"],
            },
            extract_recent,
            priority=1,
            examples=("what did I listen to yesterday", "मैंने कल क्या सुना था", "maine kal kya suna tha"),
        ),
        IntentSpec(
            "music.create_playlist",
            _M,
            "music.create_playlist",
            {
                "en": ["create a playlist", "make a playlist", "new playlist"],
                "hi": ["प्लेलिस्ट बनाओ", "नई प्लेलिस्ट"],
                "hinglish": ["playlist banao", "naya playlist", "playlist bana do"],
            },
            extract_playlist,
            priority=1,
            examples=(
                "create a playlist called Road Trip",
                "प्लेलिस्ट बनाओ रोड ट्रिप",
                "Road Trip naam ki playlist banao",
            ),
        ),
    ]
