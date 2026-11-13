"""Product normalisation: pack sizes to base units, multipacks, unit prices, names, GTINs.

Pure functions. A size that cannot be parsed returns None; nothing is guessed.
"""

from __future__ import annotations

import re
import unicodedata
from decimal import ROUND_HALF_EVEN, Decimal, InvalidOperation
from typing import Literal

from app.shopping.types import PackSize

BaseUnit = Literal["g", "ml", "count"]

# unit word -> (base unit, factor to base)
_UNITS: dict[str, tuple[BaseUnit, Decimal]] = {
    "g": ("g", Decimal(1)),
    "gm": ("g", Decimal(1)),
    "gms": ("g", Decimal(1)),
    "gram": ("g", Decimal(1)),
    "grams": ("g", Decimal(1)),
    "gr": ("g", Decimal(1)),
    "kg": ("g", Decimal(1000)),
    "kgs": ("g", Decimal(1000)),
    "kilo": ("g", Decimal(1000)),
    "kilogram": ("g", Decimal(1000)),
    "kilograms": ("g", Decimal(1000)),
    "mg": ("g", Decimal("0.001")),
    "ml": ("ml", Decimal(1)),
    "millilitre": ("ml", Decimal(1)),
    "milliliter": ("ml", Decimal(1)),
    "l": ("ml", Decimal(1000)),
    "ltr": ("ml", Decimal(1000)),
    "ltrs": ("ml", Decimal(1000)),
    "litre": ("ml", Decimal(1000)),
    "litres": ("ml", Decimal(1000)),
    "liter": ("ml", Decimal(1000)),
    "liters": ("ml", Decimal(1000)),
    "pc": ("count", Decimal(1)),
    "pcs": ("count", Decimal(1)),
    "piece": ("count", Decimal(1)),
    "pieces": ("count", Decimal(1)),
    "n": ("count", Decimal(1)),
    "nos": ("count", Decimal(1)),
    "unit": ("count", Decimal(1)),
    "units": ("count", Decimal(1)),
    "eggs": ("count", Decimal(1)),
    "sachets": ("count", Decimal(1)),
    "tablets": ("count", Decimal(1)),
}
_UNIT_RE = "|".join(sorted((re.escape(u) for u in _UNITS), key=len, reverse=True))
_NUM = r"\d+(?:\.\d+)?"
_MULTI_PREFIX = re.compile(rf"(?P<count>\d+)\s*[x×*]\s*(?P<qty>{_NUM})\s*(?P<unit>{_UNIT_RE})\b", re.I)
_MULTI_SUFFIX = re.compile(rf"(?P<qty>{_NUM})\s*(?P<unit>{_UNIT_RE})\s*[x×*]\s*(?P<count>\d+)\b", re.I)
_PACK_OF = re.compile(r"\bpack\s+of\s+(?P<count>\d+)\b", re.I)
_SINGLE = re.compile(rf"(?P<qty>{_NUM})\s*(?P<unit>{_UNIT_RE})\b", re.I)
_SIZE_ANY = re.compile(
    rf"(\d+\s*[x×*]\s*)?{_NUM}\s*(?:{_UNIT_RE})\b(\s*[x×*]\s*\d+)?|\bpack\s+of\s+\d+\b", re.I
)
_STOPWORDS = frozenset({"the", "a", "an", "of", "and", "with", "for", "pack", "new", "fresh"})


def _dec(text: str) -> Decimal | None:
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def parse_pack(label: str | None) -> PackSize | None:
    """ "2 x 500 g" -> 500 g x 2; "1 kg" -> 1000 g; "Pack of 6" (with "100 g") -> 100 g x 6.

    Returns None when no size is stated."""
    if not label:
        return None
    text = unicodedata.normalize("NFKC", label).strip()
    for pattern in (_MULTI_PREFIX, _MULTI_SUFFIX):
        match = pattern.search(text)
        if match:
            unit, factor = _UNITS[match.group("unit").lower()]
            qty = _dec(match.group("qty"))
            count = int(match.group("count"))
            if qty is None or qty <= 0 or count <= 0:
                return None
            return PackSize(quantity=qty * factor, unit=unit, count=count, label=label)
    single = _SINGLE.search(text)
    pack_of = _PACK_OF.search(text)
    count = int(pack_of.group("count")) if pack_of else 1
    if single:
        unit, factor = _UNITS[single.group("unit").lower()]
        qty = _dec(single.group("qty"))
        if qty is None or qty <= 0 or count <= 0:
            return None
        if unit == "count" and pack_of is None:
            return PackSize(quantity=Decimal(1), unit="count", count=int(qty), label=label)
        return PackSize(quantity=qty * factor, unit=unit, count=count, label=label)
    if pack_of and count > 0:
        return PackSize(quantity=Decimal(1), unit="count", count=count, label=label)
    return None


def same_size(a: PackSize | None, b: PackSize | None) -> bool:
    """Same total quantity in the same base unit (a 2 x 500 g pack equals 1 kg)."""
    if a is None or b is None:
        return False
    return a.unit == b.unit and a.total.normalize() == b.total.normalize()


def unit_price(price_paise: int, pack: PackSize | None) -> tuple[Decimal, str] | None:
    """Price per 100 g, per litre or per piece, in rupees (2 decimals). None without a size."""
    if pack is None or pack.total <= 0:
        return None
    rupees = Decimal(price_paise) / Decimal(100)
    if pack.unit == "g":
        per, label = Decimal(100), "per 100 g"
    elif pack.unit == "ml":
        per, label = Decimal(1000), "per litre"
    else:
        per, label = Decimal(1), "per piece"
    value = (rupees * per / pack.total).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
    return value, label


def strip_size(name: str) -> str:
    return _SIZE_ANY.sub(" ", name)


def normalize_name(name: str, brand: str | None = None) -> str:
    """Lowercase, accents folded, sizes and brand removed, punctuation dropped, stopwords removed."""
    text = unicodedata.normalize("NFKD", strip_size(name)).lower()
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    if brand:
        for token in normalize_brand(brand).split():
            text = re.sub(rf"\b{re.escape(token)}\b", " ", text)
    text = re.sub(r"[^\w\s]", " ", text)
    words = [w for w in text.split() if w not in _STOPWORDS]
    return " ".join(words)


def normalize_brand(brand: str | None) -> str:
    if not brand:
        return ""
    text = unicodedata.normalize("NFKD", brand).lower()
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return " ".join(re.sub(r"[^\w\s]", " ", text).split())


def valid_gtin(code: str | None) -> bool:
    """GTIN-8/12/13/14 with a correct check digit."""
    if not code or not code.isdigit() or len(code) not in (8, 12, 13, 14):
        return False
    digits = [int(d) for d in code]
    body, check = digits[:-1], digits[-1]
    total = sum(d * (3 if i % 2 == 0 else 1) for i, d in enumerate(reversed(body)))
    return (10 - total % 10) % 10 == check


def normalize_gtin(code: str | None) -> str | None:
    """GTIN padded to 14 digits, or None when invalid."""
    if code is None:
        return None
    cleaned = re.sub(r"\D", "", code)
    return cleaned.zfill(14) if valid_gtin(cleaned) else None


def identity_key(brand: str | None, name: str, pack: PackSize | None) -> str:
    """Stable identity used to match one product across providers."""
    size = f"{pack.total.normalize():f}{pack.unit}" if pack else "nosize"
    return f"{normalize_brand(brand)}|{normalize_name(name, brand)}|{size}"


def rupees_to_paise(value: object) -> int | None:
    """Parse a provider price (JSON number or string, rupees) exactly. Floats from JSON are read
    through their shortest decimal representation; None when absent or not a number."""
    if value is None or isinstance(value, bool):
        return None
    try:
        amount = Decimal(str(value).replace(",", "").replace("₹", "").strip())
    except InvalidOperation:
        return None
    if not amount.is_finite() or amount < 0:
        return None
    return int((amount * 100).quantize(Decimal(1), rounding=ROUND_HALF_EVEN))
