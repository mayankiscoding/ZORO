"""Recurring payments, subscriptions and the cash-flow forecast. Pure functions over integer paise.

Recurring: per merchant and direction, at least 3 charges (2 for yearly) whose gaps fit one cadence
(weekly 6-8 days, monthly 27-33, quarterly 85-97, yearly 350-380; at least 75% of gaps) and whose
amounts stay within 15% of the median. A series is dropped once it is overdue by half a cadence.

Forecast: projected recurring items plus the trailing 90-day average of the other debits; the
range comes from the lowest and highest of the three trailing 30-day windows.
"""

from __future__ import annotations

import calendar
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import ROUND_HALF_EVEN, Decimal
from itertools import pairwise
from statistics import median_low
from typing import Literal

from app.core.money import from_paise
from app.finance.schemas import CashflowForecast, ForecastLine, RecurringItem

Cadence = Literal["weekly", "monthly", "quarterly", "yearly"]
CADENCES: dict[Cadence, tuple[int, int, int]] = {  # (min gap, max gap, nominal days)
    "weekly": (6, 8, 7),
    "monthly": (27, 33, 30),
    "quarterly": (85, 97, 91),
    "yearly": (350, 380, 365),
}
AMOUNT_TOLERANCE_PCT = 15
STABLE_PCT = 2
NOT_SUBSCRIPTIONS = {"rent", "bills", "transfers", "salary", "interest", "cash"}
TRAILING_DAYS = 90
WINDOW_DAYS = 30


@dataclass(frozen=True)
class TxnPoint:
    id: str
    merchant_key: str
    merchant: str
    category: str
    direction: str
    txn_date: date
    paise: int


def add_months(day: date, months: int) -> date:
    month_index = day.month - 1 + months
    year, month = day.year + month_index // 12, month_index % 12 + 1
    return date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def step(day: date, cadence: Cadence) -> date:
    if cadence == "weekly":
        return day + timedelta(days=7)
    return add_months(day, {"monthly": 1, "quarterly": 3, "yearly": 12}[cadence])


def _cadence(gaps: list[int]) -> Cadence | None:
    for name, (lo, hi, _) in CADENCES.items():
        fits = sum(lo <= g <= hi for g in gaps)
        if gaps and fits * 4 >= len(gaps) * 3:
            return name
    return None


def detect_recurring(points: list[TxnPoint], as_of: date) -> list[RecurringItem]:
    groups: dict[tuple[str, str], list[TxnPoint]] = defaultdict(list)
    for p in points:
        if not p.merchant_key.startswith(("unknown", "atm withdrawal", "cash deposit")):
            groups[(p.merchant_key, p.direction)].append(p)
    items: list[RecurringItem] = []
    for (key, direction), series in sorted(groups.items()):
        series.sort(key=lambda p: (p.txn_date, p.id))
        gaps = [(b.txn_date - a.txn_date).days for a, b in pairwise(series)]
        gaps = [g for g in gaps if g > 0]
        cadence = _cadence(gaps)
        if cadence is None or len(series) < (2 if cadence == "yearly" else 3):
            continue
        amounts = [p.paise for p in series]
        typical = median_low(amounts)
        if any(abs(a - typical) * 100 > AMOUNT_TOLERANCE_PCT * typical for a in amounts):
            continue
        last = series[-1]
        nominal = CADENCES[cadence][2]
        if (as_of - last.txn_date).days > nominal + nominal // 2:
            continue  # the series stopped
        stable = (max(amounts) - min(amounts)) * 100 <= STABLE_PCT * typical
        category = last.category
        subscription = direction == "debit" and (
            category == "subscriptions"
            or (stable and cadence in ("monthly", "yearly") and category not in NOT_SUBSCRIPTIONS)
        )
        next_date = step(last.txn_date, cadence)
        while next_date <= as_of:
            next_date = step(next_date, cadence)
        items.append(
            RecurringItem(
                merchant=last.merchant, merchant_key=key, category=category,
                direction="debit" if direction == "debit" else "credit", cadence=cadence,
                typical_amount=from_paise(typical), min_amount=from_paise(min(amounts)),
                max_amount=from_paise(max(amounts)), occurrences=len(series), first_date=series[0].txn_date,
                last_date=last.txn_date, next_expected=next_date, is_subscription=subscription,
            )
        )  # fmt: skip
    return sorted(items, key=lambda i: (i.direction, -i.typical_amount, i.merchant_key))


def _scale(paise: int, num: int, den: int) -> int:
    return int((Decimal(paise) * num / den).quantize(Decimal(1), rounding=ROUND_HALF_EVEN))


def monthly_equivalent(item: RecurringItem) -> int:
    paise = int(item.typical_amount * 100)
    return {"weekly": _scale(paise, 52, 12), "monthly": paise, "quarterly": _scale(paise, 1, 3),
            "yearly": _scale(paise, 1, 12)}[item.cadence]  # fmt: skip


def forecast(
    recurring: list[RecurringItem], points: list[TxnPoint], as_of: date, horizon_days: int
) -> CashflowForecast:
    """Deterministic: the same rows, `as_of` and horizon always give the same numbers."""
    end = as_of + timedelta(days=horizon_days)
    lines: list[ForecastLine] = []
    out_recurring = in_recurring = 0
    for item in recurring:
        day, hits = item.next_expected, 0
        while day <= end:
            if day > as_of:
                hits += 1
            day = step(day, item.cadence)
        if hits == 0:
            continue
        paise = int(item.typical_amount * 100) * hits
        lines.append(ForecastLine(label=f"{item.merchant} x{hits}", direction=item.direction,
                                  amount=from_paise(paise), basis=f"recurring:{item.cadence}"))  # fmt: skip
        if item.direction == "debit":
            out_recurring += paise
        else:
            in_recurring += paise
    recurring_keys = {(i.merchant_key, i.direction) for i in recurring}
    start = as_of - timedelta(days=TRAILING_DAYS - 1)
    windows = [0, 0, 0]
    for p in points:
        if (
            p.direction != "debit"
            or (p.merchant_key, "debit") in recurring_keys
            or not start <= p.txn_date <= as_of
        ):
            continue
        windows[min((as_of - p.txn_date).days // WINDOW_DAYS, 2)] += p.paise
    trailing = sum(windows)
    expected_other = _scale(trailing, horizon_days, TRAILING_DAYS)
    scaled = [_scale(w, horizon_days, WINDOW_DAYS) for w in windows]
    lines.append(ForecastLine(label="Other spending (trailing average)", direction="debit",
                              amount=from_paise(expected_other), basis="trailing_average"))  # fmt: skip
    expected_out = out_recurring + expected_other
    return CashflowForecast(
        as_of=as_of, horizon_days=horizon_days, start=as_of + timedelta(days=1), end=end,
        expected_outflow=from_paise(expected_out),
        outflow_low=from_paise(out_recurring + min(scaled)), outflow_high=from_paise(out_recurring + max(scaled)),
        expected_inflow=from_paise(in_recurring), net=from_paise(in_recurring - expected_out),
        method=(
            f"Recurring items projected on their cadence, plus other debits at the average of the last "
            f"{TRAILING_DAYS} days scaled to {horizon_days} days; the range uses the lowest and highest "
            f"{WINDOW_DAYS}-day window. Only recurring credits count as expected income."
        ),
        lines=lines,
    )  # fmt: skip
