"""Photo-search intent: "show me the photo from yesterday with my blue cap", "kal ki photo dikhao",
"पिछले महीने की तस्वीरें". The slot is the owner's sentence; `vision.parse_photo_query` does the parsing."""

from __future__ import annotations

import re

from app.core.types import AgentId
from app.tools.intents import IntentContext, IntentSpec
from app.vision.lexicon import has_phrase, norm
from app.vision.parser import mentions_photos

KEYWORDS = {
    "en": ("photo", "photos", "picture", "pictures", "pic", "pics", "screenshot", "screenshots", "image"),
    "hi": ("फोटो", "फ़ोटो", "तस्वीर", "तस्वीरें", "स्क्रीनशॉट", "चित्र"),
    "hinglish": ("photo", "photos", "pic", "pics", "tasveer", "screenshot", "screenshots"),
}
_SEARCH = (
    "show",
    "find",
    "search",
    "look for",
    "where",
    "get",
    "open",
    "see",
    "dikhao",
    "dikha",
    "dhundo",
    "dhoondo",
    "khojo",
    "khoj",
    "dikhana",
    "दिखाओ",
    "दिखा",
    "ढूंढो",
    "खोजो",
    "ढूँढो",
    "खोज",
    "देखनी",
    "देखना",
)
_CAPTURE = (
    "take a photo",
    "take a picture",
    "take a selfie",
    "click a photo",
    "click a picture",
    "capture",
    "snap a",
    "photo kheench",
    "photo kheencho",
    "photo kheenchna",
    "photo khinch",
    "photo lo",
    "photo le",
    "फोटो खींच",
    "फोटो खींचो",
    "फोटो खींचना",
    "फोटो खींचें",
    "फोटो ले",
    "फोटो लो",
    "फोटो लेना",
    "photo kheenchni",
    "photo lena",
    "selfie le",
    "selfie lo",
    "सेल्फी ले",
    "सेल्फी लो",
)
_SEND = re.compile(r"\b(send|share|bhejo|bhej do|forward)\b|भेज")


def extract(utterance: str, ctx: IntentContext) -> dict[str, str] | None:
    if not mentions_photos(utterance):
        return None
    padded = norm(utterance)
    if any(has_phrase(padded, p) for p in _CAPTURE) and not any(has_phrase(padded, w) for w in _SEARCH):
        return None  # taking a photo is a camera action, not a search
    if _SEND.search(utterance.lower()):
        return None  # sharing is a messaging action
    return {"text": utterance.strip()[:500]}


def build_intents() -> list[IntentSpec]:
    return [
        IntentSpec(
            name="vision.find_photos",
            agent=AgentId.VISION,
            tool="vision.parse_photo_query",
            keywords=KEYWORDS,
            extract=extract,
            priority=3,
            examples=(
                "show me the photo from yesterday with my blue cap",
                "kal ki photo dikhao",
                "पिछले महीने की तस्वीरें दिखाओ",
            ),
        )
    ]
