"""Numeric guard: every number in a reply must come from a real source.

Numbers are compared after normalising digits (Devanagari and other decimal scripts to ASCII),
group separators (1,23,456 and 123,456), currency symbols and trailing zeros. A reply with a
number that no source contains is rejected by the caller, which falls back to deterministic text.
Spelled-out numbers ("five hundred", "पाँच सौ") are not detected.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable
from decimal import Decimal, InvalidOperation
from typing import Any

_NUMBER = re.compile(r"\d+(?:,\d+)*(?:\.\d+)?")


def _ascii_digits(text: str) -> str:
    if text.isascii():
        return text
    return "".join(str(unicodedata.decimal(ch)) if ch.isdecimal() and not ch.isascii() else ch for ch in text)


def _canonical(raw: str) -> str | None:
    try:
        value = Decimal(raw.replace(",", ""))
    except InvalidOperation:
        return None
    if value == value.to_integral_value():
        return str(int(value))
    return format(value.normalize(), "f")


def numbers_in_text(text: str) -> set[str]:
    """Canonical forms of every number written with digits in `text`."""
    found: set[str] = set()
    for match in _NUMBER.finditer(_ascii_digits(text)):
        canonical = _canonical(match.group())
        if canonical is not None:
            found.add(canonical)
    return found


def numbers_in_value(value: Any) -> set[str]:
    """Numbers anywhere inside a JSON-like value (tool results, cards)."""
    if value is None or isinstance(value, bool):
        return set()
    if isinstance(value, int | float | Decimal):
        canonical = _canonical(str(abs(Decimal(str(value)))))
        return {canonical} if canonical is not None else set()
    if isinstance(value, str):
        return numbers_in_text(value)
    if isinstance(value, dict):
        found: set[str] = set()
        for key, item in value.items():
            found |= numbers_in_text(str(key)) | numbers_in_value(item)
        return found
    if isinstance(value, list | tuple | set | frozenset):
        found = set()
        for item in value:
            found |= numbers_in_value(item)
        return found
    return numbers_in_text(str(value))


def invented_numbers(reply: str, sources: Iterable[Any]) -> list[str]:
    """Numbers in `reply` that appear in none of `sources`, sorted. Empty means the reply passes."""
    allowed: set[str] = set()
    for source in sources:
        allowed |= numbers_in_value(source)
    return sorted(numbers_in_text(reply) - allowed)
