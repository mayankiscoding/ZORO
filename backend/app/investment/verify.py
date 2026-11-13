"""Fact sheet, number verification and banned-claims check for investment narratives.

Every number written in a section or a model narrative must equal a fact-sheet value rounded to the
number of decimals written (sign may be dropped: "fell 3.2%" for -3.2). Dates must be fact dates.
Guaranteed-return and certain-profit wording is blocked in English, Hindi and Hinglish.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from datetime import date
from decimal import Decimal, InvalidOperation

from app.core.money import format_inr
from app.schemas.common import ZModel


class Fact(ZModel):
    key: str
    label: str
    value: Decimal
    unit: str  # "INR" | "%" | "" | "bars" | "shares"
    source: str
    as_of: date | None = None


class FactSheet:
    def __init__(self) -> None:
        self._facts: dict[str, Fact] = {}
        self.dates: set[date] = set()

    def add(
        self, key: str, label: str, value: Decimal | float | int, unit: str, source: str,
        as_of: date | None = None, places: int = 2,
    ) -> Fact:  # fmt: skip
        number = value if isinstance(value, Decimal) else Decimal(str(value))
        fact = Fact(key=key, label=label, value=round(number, places), unit=unit, source=source, as_of=as_of)
        self._facts[key] = fact
        if as_of is not None:
            self.dates.add(as_of)
        return fact

    def has(self, key: str) -> bool:
        return key in self._facts

    def get(self, key: str) -> Fact:
        return self._facts[key]

    def text(self, key: str) -> str:
        """How a fact is written in prose: rupees with Indian grouping, percent with a sign symbol."""
        fact = self._facts[key]
        if fact.unit == "INR":
            return format_inr(fact.value)
        if fact.unit == "%":
            return f"{fact.value}%"
        return str(fact.value)

    def values(self) -> list[Decimal]:
        return [f.value for f in self._facts.values()]

    def facts(self) -> list[Fact]:
        return list(self._facts.values())


_DATE = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
_NUMBER = re.compile(r"(?<![\w.])-?\d[\d,]*(?:\.\d+)?")
_DEVANAGARI_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")

BANNED_PATTERNS: tuple[re.Pattern[str], ...] = tuple(
    re.compile(p, re.IGNORECASE)
    for p in (
        r"\bguarantee(d|s)?\b", r"\bassured\s+(return|profit|gain)s?\b", r"\brisk[- ]free\b(?!\s+rate)",
        r"\b(certain|sure|confirmed)\s+(profit|gain|return)s?\b", r"\bsure[- ]shot\b", r"\bcan(no|')t\s+lose\b",
        r"\bno\s+risk\b", r"\b100\s*%\s*(safe|sure|certain)\b", r"\bdouble\s+your\s+money\b",
        r"\bwill\s+(definitely|certainly|surely)\s+(rise|go\s+up|gain|increase)\b",
        r"गारंटी", r"पक्का\s*(मुनाफ़?ा|फ़?ायदा|रिटर्न)", r"निश्चित\s*(लाभ|मुनाफ़?ा|रिटर्न)", r"बिना\s*जोखिम",
        r"\bpakka\s+(profit|munafa|return|fayda)\b", r"\bpaisa\s+double\b", r"\bloss\s+nahi\s+hoga\b",
    )
)  # fmt: skip


def banned_claims(text: str) -> list[str]:
    return [m.group(0) for p in BANNED_PATTERNS for m in [p.search(text)] if m is not None]


def _matches(number: Decimal, decimals: int, values: Iterable[Decimal]) -> bool:
    quantum = Decimal(1).scaleb(-decimals)
    for value in values:
        try:
            rounded = value.quantize(quantum)
        except InvalidOperation:
            continue
        if rounded == number or abs(rounded) == abs(number):
            return True
    return False


def check_numbers(text: str, sheet: FactSheet) -> list[str]:
    """Problems found: numbers or dates in `text` that are not on the fact sheet."""
    problems: list[str] = []
    plain = text.translate(_DEVANAGARI_DIGITS)

    def date_check(match: re.Match[str]) -> str:
        try:
            day = date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
        except ValueError:
            day = None
        if day is None or day not in sheet.dates:
            problems.append(f"date {match.group(0)} is not in the fact sheet")
        return " "

    plain = _DATE.sub(date_check, plain)
    values = sheet.values()
    for match in _NUMBER.finditer(plain):
        token = match.group(0).replace(",", "")
        number = Decimal(token)
        decimals = len(token.split(".")[1]) if "." in token else 0
        if not _matches(number, decimals, values):
            problems.append(f"{match.group(0)} does not match any fact")
    return problems


class VerificationReport(ZModel):
    passed: bool
    numbers_checked: int
    problems: list[str]
    banned_phrases: list[str]


def verify_texts(texts: Iterable[str], sheet: FactSheet) -> VerificationReport:
    problems: list[str] = []
    banned: list[str] = []
    checked = 0
    for text in texts:
        checked += len(_NUMBER.findall(_DATE.sub(" ", text.translate(_DEVANAGARI_DIGITS))))
        problems.extend(check_numbers(text, sheet))
        banned.extend(banned_claims(text))
    return VerificationReport(
        passed=not problems and not banned, numbers_checked=checked, problems=problems, banned_phrases=banned
    )
