"""Exact money maths. `Decimal` in code, integer paise in the database, decimal strings in JSON.

Floats are refused everywhere: pass `Decimal`, `int` or a decimal string.
"""

from __future__ import annotations

from collections.abc import Iterable
from decimal import ROUND_HALF_EVEN, Decimal, InvalidOperation

from app.schemas.common import Money

Amount = Decimal | int | str

TWO_PLACES = Decimal("0.01")
_HUNDRED = Decimal(100)


def to_decimal(value: Amount) -> Decimal:
    """Parse an exact amount. Floats and non-finite values raise."""
    if isinstance(value, bool | float):
        raise TypeError("money must be Decimal, int or a decimal string, never float or bool")
    if isinstance(value, Decimal):
        result = value
    elif isinstance(value, int):
        result = Decimal(value)
    elif isinstance(value, str):
        try:
            result = Decimal(value.strip().replace(",", ""))
        except InvalidOperation as exc:
            raise ValueError("not a decimal amount") from exc
    else:
        raise TypeError("money must be Decimal, int or a decimal string")
    if not result.is_finite():
        raise ValueError("money must be finite")
    return result


def round_money(value: Amount, places: int = 2) -> Decimal:
    """Round half-even (banker's rounding) to `places` decimal places."""
    return to_decimal(value).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_EVEN)


def to_paise(value: Amount) -> int:
    """Rupees -> integer paise, rounding half-even at the paisa."""
    return int((to_decimal(value) * _HUNDRED).quantize(Decimal(1), rounding=ROUND_HALF_EVEN))


def from_paise(paise: int) -> Decimal:
    """Integer paise -> rupees with exactly two decimal places."""
    if isinstance(paise, bool) or not isinstance(paise, int):
        raise TypeError("paise must be an int")
    return (Decimal(paise) / _HUNDRED).quantize(TWO_PLACES)


def sum_paise(values: Iterable[int]) -> int:
    total = 0
    for value in values:
        if isinstance(value, bool) or not isinstance(value, int):
            raise TypeError("paise must be an int")
        total += value
    return total


def percent_of_paise(paise: int, percent: Amount) -> int:
    """`percent` % of an amount in paise, rounded half-even to the paisa."""
    if isinstance(paise, bool) or not isinstance(paise, int):
        raise TypeError("paise must be an int")
    exact = Decimal(paise) * to_decimal(percent) / _HUNDRED
    return int(exact.quantize(Decimal(1), rounding=ROUND_HALF_EVEN))


def money_from_paise(paise: int, currency: str = "INR") -> Money:
    return Money(amount=from_paise(paise), currency=currency)


def money_to_paise(money: Money) -> int:
    return to_paise(money.amount)


def group_indian(digits: str) -> str:
    """Indian digit grouping of an unsigned integer string: 1234567 -> 12,34,567."""
    if not digits.isdigit():
        raise ValueError("digits only")
    digits = digits.lstrip("0") or "0"
    if len(digits) <= 3:
        return digits
    head, tail = digits[:-3], digits[-3:]
    groups: list[str] = []
    while len(head) > 2:
        groups.append(head[-2:])
        head = head[:-2]
    if head:
        groups.append(head)
    return ",".join(reversed(groups)) + "," + tail


def format_inr(value: Amount, *, symbol: str = "₹", paise: bool = True) -> str:
    """Format rupees with Indian grouping: Decimal("1234567.5") -> "₹12,34,567.50".

    `paise=False` rounds half-even to whole rupees. Negative amounts read "-₹1,234.00".
    """
    amount = round_money(value, 2 if paise else 0)
    sign = "-" if amount < 0 else ""
    text = format(abs(amount), "f")
    whole, _, fraction = text.partition(".")
    body = group_indian(whole)
    if paise:
        body = f"{body}.{fraction or '00'}"
    return f"{sign}{symbol}{body}"


def format_inr_paise(paise: int, *, symbol: str = "₹") -> str:
    return format_inr(from_paise(paise), symbol=symbol)
