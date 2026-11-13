"""Words for times, dates, numbers and durations in English, Hindi (Devanagari) and Hinglish.

Everything is matched on `norm(text)`: NFC, lower case, Devanagari digits as ASCII digits. Python's
`\\b` does not work for Devanagari (vowel signs are not `\\w`), so patterns use `L` / `R` below.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable, Mapping

_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")
_WORDCH = r"\wऀ-ॿ"
L = rf"(?<![{_WORDCH}])"  # left word boundary that understands Devanagari
R = rf"(?![{_WORDCH}])"  # right word boundary


def norm(text: str) -> str:
    """Length-preserving for ASCII and Devanagari: spans found here index the NFC original."""
    return unicodedata.normalize("NFC", text).lower().translate(_DIGITS)


def alt(words: Iterable[str]) -> str:
    """Regex alternation, longest first so "parson" wins over "parso"."""
    unique = sorted({norm(w) for w in words}, key=len, reverse=True)
    return "(?:" + "|".join(re.escape(w).replace(r"\ ", r"\s+") for w in unique) + ")"


def lookup(table: Mapping[str, int | float], word: str) -> int | float | None:
    key = re.sub(r"\s+", " ", norm(word).strip())
    return _NORMED.get(id(table), {}).get(key)


def _normed(table: Mapping[str, int | float]) -> dict[str, int | float]:
    return {norm(k): v for k, v in table.items()}


NUMBERS: dict[str, int] = {
    # English
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
    "forty": 40, "forty five": 45, "fifty": 50, "sixty": 60,
    # Hinglish
    "ek": 1, "do": 2, "teen": 3, "char": 4, "chaar": 4, "paanch": 5, "panch": 5, "chhe": 6, "chah": 6,
    "chhah": 6, "saat": 7, "aath": 8, "nau": 9, "das": 10, "gyarah": 11, "gyaarah": 11, "barah": 12,
    "baarah": 12, "pandrah": 15, "bees": 20, "pachees": 25, "tees": 30, "chalees": 40,
    "pachaas": 50, "saath": 60,
    # Hindi
    "एक": 1, "दो": 2, "तीन": 3, "चार": 4, "पांच": 5, "पाँच": 5, "छह": 6, "छः": 6, "छे": 6, "सात": 7,
    "आठ": 8, "नौ": 9, "दस": 10, "ग्यारह": 11, "बारह": 12, "पंद्रह": 15, "बीस": 20, "पच्चीस": 25,
    "तीस": 30, "चालीस": 40, "पचास": 50, "साठ": 60,
}  # fmt: skip

# Quarter words that modify the next number ("saadhe saat" = 7.5) or stand alone ("dedh" = 1.5).
PREFIX_FRACTIONS: dict[str, float] = {
    "saadhe": 0.5, "sadhe": 0.5, "saade": 0.5, "साढ़े": 0.5,
    "sawa": 0.25, "savaa": 0.25, "sava": 0.25, "सवा": 0.25,
    "paune": -0.25, "pone": -0.25, "पौने": -0.25,
}  # fmt: skip
STANDALONE_FRACTIONS: dict[str, float] = {
    "dedh": 1.5, "derh": 1.5, "डेढ़": 1.5, "dhai": 2.5, "dhaai": 2.5, "ढाई": 2.5,
    "aadha": 0.5, "aadhe": 0.5, "adha": 0.5, "आधा": 0.5, "आधे": 0.5, "half an": 0.5, "half a": 0.5,
    "a": 1, "an": 1,
}  # fmt: skip

PARTS_OF_DAY: dict[str, str] = {
    "morning": "morning", "subah": "morning", "subha": "morning", "savere": "morning",
    "सुबह": "morning", "सवेरे": "morning",
    "afternoon": "afternoon", "dopahar": "afternoon", "dopehar": "afternoon", "दोपहर": "afternoon",
    "evening": "evening", "shaam": "evening", "sham": "evening", "शाम": "evening",
    "night": "night", "tonight": "night", "raat": "night", "रात": "night",
}  # fmt: skip
DEFAULT_HOUR = {"morning": 9, "afternoon": 14, "evening": 18, "night": 21}

DAY_OFFSETS: dict[str, int] = {
    "today": 0, "aaj": 0, "aj": 0, "आज": 0, "tonight": 0,
    "tomorrow": 1, "kal": 1, "कल": 1,
    "day after tomorrow": 2, "parso": 2, "parson": 2, "parsoon": 2, "परसों": 2, "परसो": 2,
}  # fmt: skip
AMBIGUOUS_DAY_WORDS = frozenset({"kal", "कल"})  # also "yesterday"; commands are about the future

WEEKDAYS: dict[str, int] = {
    "monday": 0, "mon": 0, "somvar": 0, "somwar": 0, "सोमवार": 0,
    "tuesday": 1, "tue": 1, "tues": 1, "mangalvar": 1, "mangalwar": 1, "मंगलवार": 1,
    "wednesday": 2, "wed": 2, "budhvar": 2, "budhwar": 2, "बुधवार": 2,
    "thursday": 3, "thu": 3, "thurs": 3, "guruvar": 3, "guruwar": 3, "brihaspativar": 3,
    "गुरुवार": 3, "बृहस्पतिवार": 3, "वीरवार": 3,
    "friday": 4, "fri": 4, "shukravar": 4, "shukrawar": 4, "शुक्रवार": 4,
    "saturday": 5, "shanivar": 5, "shaniwar": 5, "शनिवार": 5,
    "sunday": 6, "ravivar": 6, "raviwar": 6, "itvaar": 6, "itwar": 6, "रविवार": 6, "इतवार": 6,
}  # fmt: skip
WEEKDAY_CODES = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")

MONTHS: dict[str, int] = {
    "january": 1, "jan": 1, "जनवरी": 1, "february": 2, "feb": 2, "फ़रवरी": 2, "फरवरी": 2,
    "march": 3, "mar": 3, "मार्च": 3, "april": 4, "apr": 4, "अप्रैल": 4, "may": 5, "मई": 5,
    "june": 6, "jun": 6, "जून": 6, "july": 7, "jul": 7, "जुलाई": 7, "august": 8, "aug": 8, "अगस्त": 8,
    "september": 9, "sep": 9, "sept": 9, "सितंबर": 9, "सितम्बर": 9, "october": 10, "oct": 10,
    "अक्टूबर": 10, "november": 11, "nov": 11, "नवंबर": 11, "नवम्बर": 11, "december": 12, "dec": 12,
    "दिसंबर": 12, "दिसम्बर": 12,
}  # fmt: skip

UNITS: dict[str, int] = {
    "second": 1, "seconds": 1, "sec": 1, "secs": 1, "सेकंड": 1,
    "minute": 60, "minutes": 60, "min": 60, "mins": 60, "minat": 60, "मिनट": 60,
    "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600, "ghanta": 3600, "ghante": 3600,
    "ghanton": 3600, "घंटा": 3600, "घंटे": 3600, "घंटों": 3600, "घण्टा": 3600, "घण्टे": 3600,
}  # fmt: skip

NEXT_WORDS = ("next", "this", "coming", "agle", "agla", "aane wale", "अगले", "अगला", "आने वाले")
BAJE = ("baje", "bje", "baj", "बजे", "o'clock", "oclock", "o clock")
AFTER_WORDS = ("baad", "bad", "mein", "me", "mai", "later", "बाद", "में", "मे")
BEFORE_WORDS = ("in", "after")

_NORMED: dict[int, dict[str, int | float]] = {
    id(t): _normed(t)
    for t in (NUMBERS, PREFIX_FRACTIONS, STANDALONE_FRACTIONS, DAY_OFFSETS, WEEKDAYS, MONTHS, UNITS)
}
