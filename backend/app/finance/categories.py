"""Category rules from `config/finance_categories.yaml` plus owner overrides.

Order: owner override for the merchant key (confidence 100) -> configured merchant match (90) ->
narration keyword (70) -> channel rule (80) -> default for the direction (0).
"""

from __future__ import annotations

import logging
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from app.finance.formats import Direction
from app.finance.normalise import Normalised, merchant_key

log = logging.getLogger(__name__)

CATEGORIES_FILE = "finance_categories.yaml"


@dataclass(frozen=True)
class CategoryDef:
    id: str
    names: Mapping[str, str]  # lang -> spoken name
    words: Mapping[str, tuple[str, ...]]  # lang -> intent words
    merchants: tuple[str, ...] = ()
    keywords: tuple[str, ...] = ()
    channels: tuple[str, ...] = ()
    direction: Direction | None = None

    def name(self, lang: str) -> str:
        return self.names.get(lang) or self.names.get("en") or self.id


@dataclass(frozen=True)
class Categorisation:
    category: str
    confidence: int  # 0..100
    source: str  # override | rule | model | default


@dataclass(frozen=True)
class CategoryConfig:
    categories: tuple[CategoryDef, ...]
    merchants: Mapping[str, str] = field(default_factory=dict)  # merchant key alias -> display name
    default_debit: str = "uncategorised"
    default_credit: str = "other_income"

    def get(self, category_id: str) -> CategoryDef | None:
        return next((c for c in self.categories if c.id == category_id), None)

    def ids(self) -> list[str]:
        return [c.id for c in self.categories]

    def name(self, category_id: str, lang: str = "en") -> str:
        found = self.get(category_id)
        return found.name(lang) if found else category_id.replace("_", " ")

    def categorise(
        self,
        norm: Normalised,
        narration: str,
        direction: Direction,
        overrides: Mapping[str, str] | None = None,
    ) -> Categorisation:
        if overrides and norm.merchant_key in overrides:
            return Categorisation(overrides[norm.merchant_key], 100, "override")
        text = narration.lower()
        allowed = [c for c in self.categories if c.direction in (None, direction)]
        best: tuple[int, str] | None = None  # longest merchant pattern wins ("swiggy instamart")
        for cat in allowed:
            for pattern in cat.merchants:
                if _matches_merchant(norm.merchant_key, pattern) and (best is None or len(pattern) > best[0]):
                    best = (len(pattern), cat.id)
        if best is not None:
            return Categorisation(best[1], 90, "rule")
        for cat in allowed:
            if norm.channel in cat.channels:
                return Categorisation(cat.id, 80, "rule")
        for cat in allowed:
            if any(k in text for k in cat.keywords):
                return Categorisation(cat.id, 70, "rule")
        default = self.default_debit if direction == "debit" else self.default_credit
        return Categorisation(default, 0, "default")

    def match_words(self, utterance: str) -> str | None:
        """The category whose intent words (any language) occur in the utterance."""
        low = f" {utterance.lower()} "
        best: tuple[int, str] | None = None
        for cat in self.categories:
            for words in cat.words.values():
                for word in words:
                    w = word.lower()
                    hit = f" {w} " in low or (not w.isascii() and w in low)
                    if hit and (best is None or len(w) > best[0]):
                        best = (len(w), cat.id)
        return best[1] if best else None


def _matches_merchant(key: str, pattern: str) -> bool:
    pat = merchant_key(pattern)
    return key == pat or key.startswith(pat + " ")


def _strs(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        return (value,)
    if isinstance(value, Sequence):
        return tuple(str(v) for v in value)
    raise ValueError("expected a list of strings")


def parse_config(data: Mapping[str, Any]) -> CategoryConfig:
    cats: list[CategoryDef] = []
    for raw in data.get("categories") or []:
        direction = raw.get("direction")
        if direction not in (None, "debit", "credit"):
            raise ValueError(f"category {raw.get('id')}: direction must be debit or credit")
        cats.append(
            CategoryDef(
                id=str(raw["id"]),
                names={str(k): str(v) for k, v in (raw.get("names") or {}).items()},
                words={str(k): _strs(v) for k, v in (raw.get("words") or {}).items()},
                merchants=_strs(raw.get("merchants")),
                keywords=tuple(k.lower() for k in _strs(raw.get("keywords"))),
                channels=_strs(raw.get("channels")),
                direction=direction,
            )
        )
    if not cats:
        raise ValueError("no categories")
    merchants = {merchant_key(str(k)): str(v) for k, v in (data.get("merchants") or {}).items()}
    config = CategoryConfig(
        categories=tuple(cats),
        merchants=merchants,
        default_debit=str(data.get("default_debit", "uncategorised")),
        default_credit=str(data.get("default_credit", "other_income")),
    )
    for default in (config.default_debit, config.default_credit):
        if config.get(default) is None:
            raise ValueError(f"default category {default!r} is not defined")
    return config


_FALLBACK = CategoryConfig(
    categories=(
        CategoryDef(
            "uncategorised", {"en": "uncategorised", "hi": "बिना श्रेणी", "hinglish": "bina category"}, {}
        ),
        CategoryDef("other_income", {"en": "other income", "hi": "अन्य आय", "hinglish": "other income"}, {}),
    )
)


class CategoryConfigSource:
    """Reloads the YAML when its modification time changes. A broken file keeps the last good
    config (or a minimal fallback) and logs once per change."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._mtime: float | None = None
        self._config = _FALLBACK
        self._loaded = False

    def current(self) -> CategoryConfig:
        try:
            mtime: float | None = self.path.stat().st_mtime
        except OSError:
            mtime = None
        if not self._loaded or mtime != self._mtime:
            self._loaded, self._mtime = True, mtime
            try:
                self._config = parse_config(yaml.safe_load(self.path.read_text(encoding="utf-8")) or {})
            except (OSError, yaml.YAMLError, ValueError, KeyError, TypeError):
                log.error("finance categories config is not valid; keeping the previous rules")
        return self._config
