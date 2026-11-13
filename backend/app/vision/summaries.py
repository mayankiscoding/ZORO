"""Spoken summaries (en, hi, hinglish) and the `photo_query` card for the vision tools.

Figures and words are taken from the result only: dates as ISO text, colours and labels as the
canonical English words the device searches with.
"""

from __future__ import annotations

from typing import Any

from app.schemas.common import UICard
from app.vision.schemas import ParsedQuery, ShowResultsOut


def _pick(lang: str, en: str, hi: str, hinglish: str) -> str:
    return {"hi": hi, "hinglish": hinglish}.get(lang, en)


def _filters(q: Any) -> list[str]:
    return [*q.colors, *q.labels, *([f'"{q.contains_text}"'] if q.contains_text else [])]


def parse_summary(r: ParsedQuery, lang: str) -> str:
    q = r.query
    parts_en: list[str] = []
    parts_hi: list[str] = []
    parts_hing: list[str] = []
    if q.date_from and q.date_to:
        if q.date_from == q.date_to:
            d = q.date_from.isoformat()
            parts_en.append(f"from {d}")
            parts_hi.append(f"{d} की")
            parts_hing.append(f"{d} ki")
        else:
            a, b = q.date_from.isoformat(), q.date_to.isoformat()
            parts_en.append(f"from {a} to {b}")
            parts_hi.append(f"{a} से {b} तक की")
            parts_hing.append(f"{a} se {b} tak ki")
    kinds = {
        "screenshot": ("screenshots", "स्क्रीनशॉट", "screenshots"),
        "photo": ("photos only", "सिर्फ़ फ़ोटो", "sirf photos"),
        "any": ("photos", "फ़ोटो", "photos"),
    }
    noun = kinds[q.media]
    tail = f" with {', '.join(_filters(q))}" if _filters(q) else ""
    tail_hi = f", खोज: {', '.join(_filters(q))}" if _filters(q) else ""
    tail_hing = f", search: {', '.join(_filters(q))}" if _filters(q) else ""
    when_en = (" " + " ".join(parts_en)) if parts_en else ""
    when_hi = (" ".join(parts_hi) + " ") if parts_hi else ""
    when_hing = (" ".join(parts_hing) + " ") if parts_hing else ""
    return _pick(
        lang,
        f"Searching your iPhone for {noun[0]}{when_en}{tail}.",
        f"आपके iPhone पर {when_hi}{noun[1]} खोज रहा हूँ{tail_hi}।",
        f"Aapke iPhone par {when_hing}{noun[2]} dhoondh raha hoon{tail_hing}.",
    )


def show_summary(r: ShowResultsOut, lang: str) -> str:
    n = len(r.hits)
    note_en = (
        f" Only part of the library is available; {r.indexed_count} photos are indexed."
        if r.limited_library
        else ""
    )
    note_hi = (
        f" लाइब्रेरी का सिर्फ़ एक हिस्सा उपलब्ध है; {r.indexed_count} फ़ोटो इंडेक्स हैं।" if r.limited_library else ""
    )
    note_hing = (
        f" Library ka sirf ek hissa available hai; {r.indexed_count} photos indexed hain."
        if r.limited_library
        else ""
    )
    if n == 0:
        return _pick(
            lang,
            f"No matching photos on your iPhone; {r.indexed_count} photos are indexed.{note_en if r.limited_library else ''}",
            f"आपके iPhone पर कोई मिलती-जुलती फ़ोटो नहीं मिली; {r.indexed_count} फ़ोटो इंडेक्स हैं।{note_hi}",
            f"Aapke iPhone par koi matching photo nahi mili; {r.indexed_count} photos indexed hain.{note_hing}",
        )
    return _pick(
        lang,
        f"Found {n} matching photos on your iPhone.{note_en}",
        f"आपके iPhone पर {n} मिलती-जुलती फ़ोटो मिलीं।{note_hi}",
        f"Aapke iPhone par {n} matching photos mili.{note_hing}",
    )


def query_chips(q: Any) -> list[dict[str, str]]:
    chips: list[dict[str, str]] = []
    if q.date_from and q.date_to:
        chips.append(
            {
                "kind": "date",
                "label": q.date_from.isoformat()
                if q.date_from == q.date_to
                else f"{q.date_from.isoformat()} to {q.date_to.isoformat()}",
            }
        )
    chips += [{"kind": "color", "label": c} for c in q.colors] + [
        {"kind": "label", "label": x} for x in q.labels
    ]
    if q.contains_text:
        chips.append({"kind": "text", "label": q.contains_text})
    if q.media != "any":
        chips.append({"kind": "media", "label": q.media})
    return chips


def parse_card(r: ParsedQuery) -> UICard:
    return UICard(
        kind="photo_query",
        title="Photo search",
        payload={
            "query": r.query.model_dump(mode="json"),
            "chips": query_chips(r.query),
            "asset_ids": [],
            "hits": [],
            "state": "searching",
            "assumptions": r.assumptions,
        },
    )


def show_card(r: ShowResultsOut) -> UICard:
    return UICard(
        kind="photo_query",
        title="Photos",
        payload={
            "query": r.query.model_dump(mode="json"),
            "chips": query_chips(r.query),
            "asset_ids": r.asset_ids,
            "hits": [h.model_dump(mode="json") for h in r.hits],
            "state": "found" if r.hits else "empty",
            "indexed_count": r.indexed_count,
            "limited_library": r.limited_library,
        },
    )
