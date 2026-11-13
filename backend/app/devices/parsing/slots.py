"""Slot helpers: device targeting, title extraction, repeat days, phone numbers, on/off."""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable, Sequence

from app.core.types import DevicePlatform
from app.devices.parsing.lexicon import WEEKDAY_CODES, WEEKDAYS, L, R, alt, lookup, norm

Span = tuple[int, int]

# ---------------------------------------------------------------- "on my Mac" / "phone par"

_MAC = ("mac", "macbook", "मैक", "laptop", "लैपटॉप", "computer", "कंप्यूटर")
_PHONE_WORDS = ("iphone", "phone", "फ़ोन", "फोन", "आईफ़ोन", "आईफोन", "mobile", "मोबाइल")
_TARGET = re.compile(
    rf"{L}(?:(?:on|in)\s+(?:my\s+|the\s+)?(?P<en>{alt(_MAC + _PHONE_WORDS)})"
    rf"|(?:mere\s+|मेरे\s+)?(?P<hi>{alt(_MAC + _PHONE_WORDS)})\s+(?:par|pe|pr|mein|me|पर|पे|में)){R}"
)


def extract_target(text: str) -> tuple[DevicePlatform | None, Span | None]:
    m = _TARGET.search(norm(text))
    if m is None:
        return None, None
    word = m.group("en") or m.group("hi")
    platform = DevicePlatform.MACOS if word in {norm(w) for w in _MAC} else DevicePlatform.IOS
    return platform, m.span()


# ---------------------------------------------------------------- titles


_EDGE_WORDS = (
    "to", "at", "on", "by", "for", "about", "that", "please", "the", "a", "an", "and", "my", "me", "with",
    "ko", "ki", "ka", "ke", "se", "par", "pe", "zara", "jara", "plz", "liye", "ke liye",
    "को", "की", "का", "के", "से", "पर", "ज़रा", "जरा", "लिए", "के लिए", "और",
)  # fmt: skip
_EDGE = re.compile(rf"^(?:{alt(_EDGE_WORDS)}{R}[\s,.!?।]*)+|(?:[\s,.!?।]*{L}{alt(_EDGE_WORDS)})+$")


def remove_spans(text: str, spans: Iterable[Span]) -> str:
    """Blank out spans (indices of `norm(text)`, which keeps the original's length)."""
    chars = list(unicodedata.normalize("NFC", text))
    for start, end in spans:
        for i in range(max(0, start), min(len(chars), end)):
            chars[i] = " "
    return "".join(chars)


def clean_title(text: str, triggers: Sequence[str], spans: Iterable[Span] = ()) -> str:
    """What is left of an utterance once times, targets and command words are removed."""
    original = remove_spans(text, spans)
    pattern = re.compile(rf"{L}{alt(triggers)}{R}") if triggers else None
    lowered = norm(original)
    if pattern is not None:
        original = remove_spans(original, (m.span() for m in pattern.finditer(lowered)))
    title = re.sub(r"\s+", " ", original).strip(" ,.!?।")
    previous = None
    while previous != title:
        previous = title
        lowered = norm(title)
        m = _EDGE.search(lowered)
        if m is not None and m.group(0):
            title = (title[: m.start()] + title[m.end() :]).strip(" ,.!?।")
    return title


# ---------------------------------------------------------------- alarm repeat days

_DAILY = ("every day", "everyday", "daily", "roz", "rozana", "har din", "रोज़", "रोज", "रोज़ाना", "हर दिन")
_WEEKDAYS_WORD = ("weekdays", "every weekday", "working days")
_WEEKENDS_WORD = ("weekends", "every weekend", "weekend")
_EVERY = re.compile(rf"{L}(?:every|har|हर)\s+(?P<wd>{alt(WEEKDAYS)}){R}")


def extract_repeat_days(text: str) -> tuple[list[str] | None, list[Span]]:
    t = norm(text)
    if m := re.search(rf"{L}{alt(_DAILY)}{R}", t):
        return list(WEEKDAY_CODES), [m.span()]
    if m := re.search(rf"{L}{alt(_WEEKDAYS_WORD)}{R}", t):
        return list(WEEKDAY_CODES[:5]), [m.span()]
    if m := re.search(rf"{L}{alt(_WEEKENDS_WORD)}{R}", t):
        return list(WEEKDAY_CODES[5:]), [m.span()]
    found = list(_EVERY.finditer(t))
    if found:
        days = sorted({int(lookup(WEEKDAYS, m.group("wd")) or 0) for m in found})
        return [WEEKDAY_CODES[d] for d in days], [m.span() for m in found]
    return None, []


# ---------------------------------------------------------------- phone numbers and email

_PHONE = re.compile(r"(?<![\d])(?:\+\s?)?\d[\d\s-]{8,16}\d(?![\d])")
_EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[A-Za-z]{2,}")


def extract_phone(text: str, default_country: str = "91") -> tuple[str | None, Span | None]:
    """International digits. A 10-digit number gets the owner's country code (India by default)."""
    t = norm(text)
    m = _PHONE.search(t)
    if m is None:
        return None, None
    raw = m.group(0)
    digits = re.sub(r"\D", "", raw)
    if raw.lstrip().startswith("+") or len(digits) > 10:
        if 8 <= len(digits) <= 15:
            return digits, m.span()
        return None, None
    if len(digits) == 10:
        return default_country + digits, m.span()
    return None, None


def extract_email(text: str) -> tuple[str | None, Span | None]:
    m = _EMAIL.search(text)
    return (m.group(0), m.span()) if m else (None, None)


# ---------------------------------------------------------------- switching things on and off

_ON = ("on", "turn on", "switch on", "chalu", "chaalu", "jalao", "jala do", "on karo", "on kar do",
       "चालू", "जलाओ", "जला दो", "ऑन")  # fmt: skip
_OFF = ("off", "turn off", "switch off", "band", "bujhao", "bujha do", "off karo", "off kar do",
        "बंद", "बुझाओ", "बुझा दो", "ऑफ")  # fmt: skip


def extract_switch(text: str) -> str | None:
    """ "turn_on" / "turn_off" (the last one said wins: "band nahi, on karo" is rare enough)."""
    t = norm(text)
    on = [m.end() for m in re.finditer(rf"{L}{alt(_ON)}{R}", t)]
    off = [m.end() for m in re.finditer(rf"{L}{alt(_OFF)}{R}", t)]
    if not on and not off:
        return None
    return "turn_on" if max(on, default=-1) > max(off, default=-1) else "turn_off"
