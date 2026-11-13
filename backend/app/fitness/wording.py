"""Wording check: fitness information only (CLAUDE.md rule 10). No diagnosis, no medication advice.

Everything ZORO says about resting heart rate, sleep or recovery passes through `check_wording`;
text that names a condition, a diagnosis, a drug or a dose is refused and dropped. The check is a
deny-list in English, Hindi and Hinglish, applied to templates (tests run it over every template)
and to any text a caller wants to publish.
"""

from __future__ import annotations

import re
from collections.abc import Iterable


class WordingViolation(ValueError):
    def __init__(self, hits: list[str]) -> None:
        super().__init__("not fitness information: " + ", ".join(hits))
        self.hits = hits


_EN = (
    r"diagnos\w*",
    r"disease\w*",
    r"disorder\w*",
    r"syndrome",
    r"infection\w*",
    r"illness\w*",
    r"sick\w*",
    r"medicat\w*",
    r"medicine\w*",
    r"drug\w*",
    r"prescri\w+",
    r"dosage",
    r"\bdoses?\b",
    r"antibiotic\w*",
    r"painkiller\w*",
    r"supplement\w*",
    r"therap\w+",
    r"\btreat\w*",
    r"\bcure\w*",
    r"symptom\w*",
    r"hypertension",
    r"hypotension",
    r"arrhythmi\w*",
    r"tachycardi\w*",
    r"bradycardi\w*",
    r"atrial",
    r"fibrillation",
    r"heart attack",
    r"cardiac",
    r"apnou?ea",
    r"insomnia",
    r"diabet\w*",
    r"anemi\w*",
    r"anaemi\w*",
    r"thyroid",
    r"depress\w*",
    r"anxiety",
    r"you have (a|an) ",
    r"you may have",
    r"you might have",
    r"you are suffering",
)
_HI = (
    "बीमार",
    "रोग",
    "निदान",
    "दवा",
    "दवाई",
    "दवाइयाँ",
    "इलाज",
    "लक्षण",
    "संक्रमण",
    "मधुमेह",
    "डायबिटीज़",
    "डायबिटीज",
    "उच्च रक्तचाप",
    "हाई बीपी",
    "थायराइड",
    "अनिद्रा",
    "हृदय रोग",
    "दिल का दौरा",
    "खुराक",
)
_HINGLISH = (
    r"bimari",
    r"bimar\b",
    r"beemari",
    r"rog\b",
    r"nidaan",
    r"dawa\b",
    r"dawai",
    r"dawaiyan",
    r"davai",
    r"ilaaj",
    r"ilaj",
    r"lakshan",
    r"sankraman",
    r"madhumeh",
    r"diabetes",
    r"thyroid",
    r"high bp",
    r"heart attack",
    r"khurak",
)

_PATTERNS = tuple(re.compile(p, re.IGNORECASE) for p in (*_EN, *_HINGLISH))


def check_wording(text: str) -> list[str]:
    """The deny-list hits in `text` (empty when the wording is acceptable)."""
    hits = [m.group(0) for pattern in _PATTERNS if (m := pattern.search(text))]
    hits += [word for word in _HI if word in text]
    return hits


def ensure_fitness_wording(text: str) -> str:
    hits = check_wording(text)
    if hits:
        raise WordingViolation(hits)
    return text


def clean_lines(lines: Iterable[str]) -> list[str]:
    """Keep only the lines that pass the check."""
    return [line for line in lines if not check_wording(line)]
