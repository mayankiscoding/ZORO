"""Deterministic parser: the owner's words -> `PhotoQuery` (no model, no network).

Reads, in this order: a date expression (see `dates`), a result count, screenshot / document hints,
text to find (quoted, or after "says" / "jisme ... likha"), then colour and object words from the
lexicon. `text` keeps the owner's own sentence; the structured fields come only from these rules.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from app.vision.dates import DateMatch, local_today, resolve_dates
from app.vision.lexicon import (
    COLORS,
    DOCUMENTS,
    NOT_SCREENSHOT_WORDS,
    OBJECTS,
    PHOTO_WORDS,
    SCREENSHOT_WORDS,
    find_phrase,
    has_phrase,
    norm,
)
from app.vision.schemas import DEFAULT_LIMIT, MAX_LIMIT, MAX_TEXT, Media, PhotoQuery

_PHOTO_NOUNS = "|".join(
    sorted((re.escape(norm(w).strip()) for w in (*PHOTO_WORDS, *SCREENSHOT_WORDS)), key=len, reverse=True)
)
_LIMIT = re.compile(
    rf" (?:(?:top|first|latest|last|recent|only|pehli|pehle|पहली|पहले) )?(?P<n>\d{{1,3}}) (?:{_PHOTO_NOUNS}) "
)
_LIMIT_AFTER = re.compile(rf" (?:{_PHOTO_NOUNS}) (?P<n>\d{{1,3}}) ")

_QUOTED = re.compile(
    r"[\"“”](?P<q>[^\"“”]{1,200})[\"“”]|(?:(?<=\s)|^)['‘](?P<s>[^'‘’]{1,200})['’](?=[\s,.!?]|$)"
)
_TEXT_AFTER = re.compile(
    r" (?:that says|which says|saying|says|that reads|which reads|reads|with the text|with text|with the words?|"
    r"containing the text|containing|contains|jisme|jis par|jis pe|जिसमें|जिस पर|जिसपर) (?P<t>.+?)(?: (?:likha|likhi|लिखा|लिखी)(?: hai| ho| hua| है| हो| हुआ)?)? $"
)
_TEXT_BEFORE_VERB = re.compile(
    r" (?:jisme|jis par|jis pe|जिसमें|जिस पर|जिसपर) (?P<t>.+?) (?:likha|likhi|लिखा|लिखी)(?= )"
)
_STOP = {
    "from",
    "taken",
    "on",
    "in",
    "of",
    "and",
    "with",
    "ke",
    "ka",
    "ki",
    "se",
    "mein",
    "में",
    "से",
    "के",
    "का",
    "की",
    "ko",
    "को",
    "at",
    "during",
    "last",
    "this",
}
_FILLER = {
    "the",
    "a",
    "an",
    "my",
    "me",
    "i",
    "of",
    "photo",
    "photos",
    "picture",
    "pictures",
    "pic",
    "pics",
    "show",
    "find",
}


@dataclass(frozen=True)
class Parsed:
    query: PhotoQuery
    assumptions: tuple[str, ...]
    matched: dict[str, Any]


def _phrase_index() -> dict[str, tuple[str, str]]:
    """normalised phrase -> (kind, key)"""
    index: dict[str, tuple[str, str]] = {}
    for key, words in COLORS.items():
        for w in words:
            index[norm(w).strip()] = ("color", key)
    for key, (_labels, words) in OBJECTS.items():
        for w in words:
            index.setdefault(norm(w).strip(), ("object", key))
    return index


_INDEX = _phrase_index()
_PHRASES = sorted(_INDEX, key=lambda s: (-len(s.split()), -len(s)))
_PHRASE_RE = re.compile(r"(?<= )(" + "|".join(re.escape(p) for p in _PHRASES) + r")(?= )")


def _find_filters(padded: str) -> tuple[list[tuple[int, str, str]], str]:
    """Colour and object hits in order of appearance (non-overlapping, longest phrase first)."""
    hits: list[tuple[int, str, str]] = []
    text = padded
    for m in _PHRASE_RE.finditer(padded):
        kind, key = _INDEX[m.group(1)]
        hits.append((m.start(), kind, key))
        text = text[: m.start()] + " " * (m.end() - m.start()) + text[m.end() :]
    return hits, text


def _quoted_text(original: str) -> str | None:
    m = _QUOTED.search(original)
    if m is None:
        return None
    found = (m.group("q") or m.group("s") or "").strip()
    return found or None


def _spoken_text(padded: str) -> str | None:
    m = _TEXT_BEFORE_VERB.search(padded) or _TEXT_AFTER.search(padded)
    if m is None:
        return None
    words: list[str] = []
    for word in m.group("t").split():
        if word in _STOP:
            break
        words.append(word)
    while words and words[0] in _FILLER:
        words.pop(0)
    return " ".join(words[:6]) or None


def parse_photo_query(
    text: str, now: datetime, tz: str = "Asia/Kolkata", *, default_limit: int = DEFAULT_LIMIT
) -> Parsed:
    """Parse one request. `now` is the injected clock; dates resolve in `tz`."""
    original = text.strip()[:MAX_TEXT]
    today, tz_note = local_today(now, tz)
    assumptions: list[str] = [tz_note] if tz_note else []
    padded = norm(original)
    matched: dict[str, Any] = {}

    date_from = date_to = None
    found: DateMatch | None = resolve_dates(padded, today)
    if found is not None:
        date_from, date_to = found.start, found.end
        padded = found.remaining
        assumptions += list(found.assumptions)
        matched["date"] = found.label

    limit = default_limit
    count = _LIMIT.search(padded) or _LIMIT_AFTER.search(padded)
    if count is not None:
        n = int(count.group("n"))
        if n >= 1:
            limit = min(n, MAX_LIMIT)
            if n > MAX_LIMIT:
                assumptions.append(f"At most {MAX_LIMIT} photos are returned at a time.")
            matched["limit"] = limit
            padded = padded[: count.start()] + " " * (count.end() - count.start()) + padded[count.end() :]

    media: Media = "any"
    if find_phrase(padded, SCREENSHOT_WORDS):
        media = "screenshot"
        if find_phrase(padded, NOT_SCREENSHOT_WORDS):
            media = "photo"
        matched["media"] = media

    labels: list[str] = []
    for words, doc_labels in DOCUMENTS:
        if find_phrase(padded, words):
            labels += [label for label in doc_labels if label not in labels]
            matched["document"] = True

    contains = _quoted_text(original) or _spoken_text(padded)
    if contains:
        matched["contains_text"] = contains

    hits, _rest = _find_filters(padded)
    colors: list[str] = []
    for _pos, kind, key in hits:
        if kind == "color" and key not in colors:
            colors.append(key)
        elif kind == "object":
            labels += [label for label in OBJECTS[key][0] if label not in labels]
    if colors:
        matched["colors"] = colors
    if any(kind == "object" for _, kind, _ in hits):
        matched["objects"] = [key for _, kind, key in hits if kind == "object"]

    query = PhotoQuery(
        text=original,
        date_from=date_from,
        date_to=date_to,
        colors=colors,
        labels=labels[:20],
        contains_text=contains[:200] if contains else None,
        media=media,
        limit=limit,
    )
    return Parsed(query=query, assumptions=tuple(assumptions), matched=matched)


def mentions_photos(text: str) -> bool:
    """True when the sentence talks about photos, pictures or screenshots."""
    padded = norm(text)
    return find_phrase(padded, PHOTO_WORDS) is not None or find_phrase(padded, SCREENSHOT_WORDS) is not None


__all__ = ["Parsed", "has_phrase", "mentions_photos", "parse_photo_query"]
