"""Deterministic message composition: language, light tidy-up, email greeting, subject, WhatsApp link."""

from __future__ import annotations

import re
from typing import Literal
from urllib.parse import quote

Language = Literal["en", "hi", "hinglish"]
_DEVANAGARI = re.compile(r"[ऀ-ॿ]")
_GREETING = re.compile(r"^\s*(hi|hello|hey|dear|namaste|namaskar|नमस्ते|नमस्कार|प्रिय)\b", re.IGNORECASE)
_END = ".!?।…"


def detect_language(text: str, request_lang: str = "en") -> Language:
    """The language of the words being sent: Devanagari means Hindi; Latin script follows the request
    (a Hinglish request gives a Hinglish message, anything else English)."""
    if _DEVANAGARI.search(text):
        return "hi"
    return "hinglish" if request_lang == "hinglish" else "en"


def tidy(text: str) -> str:
    """Collapse stray whitespace and capitalise a leading Latin letter. Words are never changed."""
    cleaned = re.sub(r"[ \t]+", " ", text.replace("\r\n", "\n")).strip()
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    return cleaned[:1].upper() + cleaned[1:] if cleaned[:1].isascii() else cleaned


def first_name(display: str) -> str:
    word = display.strip().split(" ")[0] if display.strip() else ""
    return "" if "@" in word or word.startswith("+") or word[:1].isdigit() else word


def email_body(text: str, language: Language, recipient_display: str) -> str:
    """Add a greeting in the message's language unless the text already opens with one."""
    body = tidy(text)
    name = first_name(recipient_display)
    if _GREETING.match(body) or not name:
        return body
    greeting = {"en": f"Hello {name},", "hi": f"नमस्ते {name},", "hinglish": f"Namaste {name},"}[language]
    return f"{greeting}\n\n{body}"


def default_subject(text: str, language: Language) -> str:
    """First sentence of the message, at most 60 characters, when the owner gave no subject."""
    sentence = re.split(r"(?<=[.!?।])\s|\n", text.strip(), maxsplit=1)[0].strip().rstrip(_END)
    if not sentence:
        return {"en": "Message", "hi": "संदेश", "hinglish": "Message"}[language]
    return sentence if len(sentence) <= 60 else sentence[:57].rstrip() + "..."


def wa_link(digits: str, text: str | None = None) -> str:
    """https://wa.me/<digits>?text=<percent-encoded UTF-8>. Digits only, no plus sign."""
    if not re.fullmatch(r"[1-9]\d{7,14}", digits):
        raise ValueError("wa.me needs international digits")
    link = f"https://wa.me/{digits}"
    return f"{link}?text={quote(text, safe='')}" if text else link
