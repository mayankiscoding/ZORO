"""Indian statement number and date formats, parsed exactly (Decimal, never float).

Amounts: ``1,23,456.78`` (Indian grouping), ``1,234,567.00``, ``Rs. 500``, ``₹500``, ``INR 500``,
``500.00 Dr`` / ``Cr``, ``(1,234.00)`` (bracket negative), ``1,234.00-`` (trailing minus),
``-500`` / ``+1,000`` (signed UPI app exports). Dates are day first: ``dd/mm/yyyy``, ``dd/mm/yy``,
``dd-mm-yyyy``, ``dd.mm.yyyy``, ``dd-MMM-yy``, ``dd MMM yyyy``, ``MMM dd, yyyy`` and ISO
``yyyy-mm-dd``, each optionally followed by a time.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from typing import Literal

Direction = Literal["debit", "credit"]

_BLANK = {"", "-", "--", "—", "nil", "na", "n/a", "none", "null"}
_CURRENCY = re.compile(r"(?i)(₹|rs\.?|inr)")
_DRCR = re.compile(r"(?i)\b(dr|cr|debit|credit)\.?\s*$")
_LEADING_DRCR = re.compile(r"(?i)^(dr|cr)\.?\s+")
_NUMBER = re.compile(r"^\d{1,3}(,\d{2})*(,\d{3})$|^\d{1,3}(,\d{3})+$|^\d+$")


class AmountError(ValueError):
    """The cell is not an amount."""


@dataclass(frozen=True)
class ParsedAmount:
    value: Decimal  # always >= 0
    sign: int  # -1 negative (debit hint), +1 explicit positive, 0 no sign given
    direction: Direction | None  # from a Dr / Cr marker


def parse_amount(text: str | int | Decimal | None) -> ParsedAmount | None:
    """Parse one amount cell. Blank cells return None; anything else that is not an amount raises."""
    if text is None:
        return None
    if isinstance(text, bool | float):
        raise AmountError("floats are not accepted: pass the cell text")
    if isinstance(text, int | Decimal):
        value = Decimal(text)
        return ParsedAmount(abs(value), -1 if value < 0 else 0, None)
    raw = text.strip().replace(" ", " ")
    if raw.lower() in _BLANK:
        return None
    direction: Direction | None = None
    marker = _DRCR.search(raw) or _LEADING_DRCR.search(raw)
    if marker:
        direction = "debit" if marker.group(1).lower().startswith("d") else "credit"
        raw = (raw[: marker.start()] + raw[marker.end() :]).strip()
    raw = _CURRENCY.sub("", raw).replace(" ", "")
    sign = 0
    if raw.startswith("(") and raw.endswith(")"):
        sign, raw = -1, raw[1:-1]
    if raw.endswith("-"):
        sign, raw = -1, raw[:-1]
    if raw.startswith("-"):
        sign, raw = -1, raw[1:]
    elif raw.startswith("+"):
        sign, raw = 1, raw[1:]
    raw = _CURRENCY.sub("", raw)
    whole, dot, fraction = raw.partition(".")
    if not whole and dot:
        whole = "0"
    if not _NUMBER.match(whole) or (dot and not fraction.isdigit()):
        raise AmountError("not an amount")
    try:
        value = Decimal(whole.replace(",", "") + (dot + fraction if dot else ""))
    except InvalidOperation as exc:  # pragma: no cover - guarded by the regex
        raise AmountError("not an amount") from exc
    if not value.is_finite():
        raise AmountError("not an amount")
    return ParsedAmount(value, sign, direction)


def signed(amount: ParsedAmount) -> Decimal:
    """Amount with its sign applied (a Dr marker counts as negative)."""
    if amount.sign < 0 or amount.direction == "debit":
        return -amount.value
    return amount.value


# ---------------------------------------------------------------- dates

_MONTHS = {
    m: i
    for i, names in enumerate(
        [
            ("jan", "january"), ("feb", "february"), ("mar", "march"), ("apr", "april"),
            ("may",), ("jun", "june"), ("jul", "july"), ("aug", "august"),
            ("sep", "sept", "september"), ("oct", "october"), ("nov", "november"), ("dec", "december"),
        ],
        start=1,
    )
    for m in names
}  # fmt: skip

_TIME = re.compile(r"[ ,T]+\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\s*([ap]\.?m\.?)?\s*(z|[+-]\d{2}:?\d{2})?$", re.I)
_NUMERIC = re.compile(r"^(\d{1,2})[/\-. ](\d{1,2})[/\-. ](\d{2}|\d{4})$")
_ISO = re.compile(r"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$")
_NAMED = re.compile(r"^(\d{1,2})(?:st|nd|rd|th)?[\-/ .]?([a-z]{3,9})[\-/ .,]*(\d{2}|\d{4})$", re.I)
_NAMED_US = re.compile(r"^([a-z]{3,9})[ .]+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})$", re.I)


class DateError(ValueError):
    """The cell is not a date."""


def _year(text: str) -> int:
    year = int(text)
    return year + 2000 if year < 100 else year


def parse_date(text: str | date | None) -> date:
    """Parse a statement date (day first). Raises `DateError`."""
    if isinstance(text, datetime):
        return text.date()
    if isinstance(text, date):
        return text
    if text is None:
        raise DateError("empty date")
    raw = _TIME.sub("", text.strip()).strip()
    try:
        if m := _ISO.match(raw):
            return date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        if m := _NUMERIC.match(raw):
            return date(_year(m.group(3)), int(m.group(2)), int(m.group(1)))
        if m := _NAMED.match(raw):
            month = _MONTHS.get(m.group(2).lower())
            if month is not None:
                return date(_year(m.group(3)), month, int(m.group(1)))
        if m := _NAMED_US.match(raw):
            month = _MONTHS.get(m.group(1).lower())
            if month is not None:
                return date(int(m.group(3)), month, int(m.group(2)))
    except ValueError as exc:
        raise DateError("impossible date") from exc
    raise DateError("not a date")


def looks_like_date(text: str) -> bool:
    try:
        parse_date(text)
    except DateError:
        return False
    return True
