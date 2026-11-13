"""Reporting periods: a stable key ("last_month", "2026-10", "last_30_days") -> dates and labels.

Labels exist in en, hi (Devanagari) and hinglish so summaries can state the period in the owner's
language. Dates are calendar dates in the owner's timezone; `end` is inclusive.
"""

from __future__ import annotations

import calendar
import re
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from pydantic import BaseModel

MONTHS_EN = [calendar.month_name[i] for i in range(1, 13)]
MONTHS_HI = ["जनवरी", "फ़रवरी", "मार्च", "अप्रैल", "मई", "जून", "जुलाई", "अगस्त", "सितंबर", "अक्टूबर", "नवंबर", "दिसंबर"]


class Period(BaseModel):
    key: str
    start: date
    end: date  # inclusive
    label_en: str
    label_hi: str
    label_hinglish: str

    def label(self, lang: str) -> str:
        return {"hi": self.label_hi, "hinglish": self.label_hinglish}.get(lang, self.label_en)

    @property
    def days(self) -> int:
        return (self.end - self.start).days + 1


class PeriodError(ValueError):
    pass


def local_today(now: datetime, timezone: str = "Asia/Kolkata") -> date:
    return now.astimezone(ZoneInfo(timezone)).date()


def _month_end(year: int, month: int) -> date:
    return date(year, month, calendar.monthrange(year, month)[1])


def _month(key: str, year: int, month: int) -> Period:
    return Period(
        key=key,
        start=date(year, month, 1),
        end=_month_end(year, month),
        label_en=f"{MONTHS_EN[month - 1]} {year}",
        label_hi=f"{MONTHS_HI[month - 1]} {year}",
        label_hinglish=f"{MONTHS_EN[month - 1]} {year}",
    )


def _year(key: str, year: int) -> Period:
    return Period(
        key=key, start=date(year, 1, 1), end=date(year, 12, 31),
        label_en=str(year), label_hi=f"साल {year}", label_hinglish=f"saal {year}",
    )  # fmt: skip


def _range(start: date, end: date) -> Period:
    def en(d: date) -> str:
        return f"{d.day} {MONTHS_EN[d.month - 1][:3]} {d.year}"

    def hi(d: date) -> str:
        return f"{d.day} {MONTHS_HI[d.month - 1]} {d.year}"

    return Period(
        key=f"{start.isoformat()}..{end.isoformat()}",
        start=start,
        end=end,
        label_en=f"{en(start)} to {en(end)}",
        label_hi=f"{hi(start)} से {hi(end)} तक",
        label_hinglish=f"{en(start)} se {en(end)} tak",
    )


_LAST_N = re.compile(r"^last_(\d{1,3})_days$")
_MONTH_KEY = re.compile(r"^(\d{4})-(\d{2})$")
_YEAR_KEY = re.compile(r"^(\d{4})$")
_RANGE_KEY = re.compile(r"^(\d{4}-\d{2}-\d{2})\.\.(\d{4}-\d{2}-\d{2})$")


def resolve_period(key: str | None, today: date) -> Period:
    """Resolve a period key relative to `today`. Unknown keys raise `PeriodError`."""
    key = (key or "this_month").strip().lower()
    if key == "this_month":
        p = _month(key, today.year, today.month)
        return p.model_copy(update={"end": today})
    if key == "last_month":
        first = date(today.year, today.month, 1) - timedelta(days=1)
        return _month(key, first.year, first.month)
    if key == "this_year":
        p = _year(key, today.year)
        return p.model_copy(update={"end": today, "label_en": f"this year ({today.year})",
                                    "label_hi": f"इस साल ({today.year})", "label_hinglish": f"is saal ({today.year})"})  # fmt: skip
    if key == "last_year":
        return _year(key, today.year - 1)
    if key in ("today", "yesterday"):
        day = today if key == "today" else today - timedelta(days=1)
        labels = {"today": ("today", "आज", "aaj"), "yesterday": ("yesterday", "कल", "kal")}[key]
        return Period(
            key=key, start=day, end=day, label_en=labels[0], label_hi=labels[1], label_hinglish=labels[2]
        )
    if key in ("this_week", "last_week"):
        monday = today - timedelta(days=today.weekday())
        if key == "last_week":
            monday -= timedelta(days=7)
            labels = ("last week", "पिछले हफ़्ते", "pichhle hafte")
            end = monday + timedelta(days=6)
        else:
            labels, end = ("this week", "इस हफ़्ते", "is hafte"), today
        return Period(
            key=key, start=monday, end=end, label_en=labels[0], label_hi=labels[1], label_hinglish=labels[2]
        )
    if m := _LAST_N.match(key):
        n = int(m.group(1))
        if not 1 <= n <= 730:
            raise PeriodError("last_N_days needs 1..730 days")
        return Period(
            key=key, start=today - timedelta(days=n - 1), end=today,
            label_en=f"the last {n} days", label_hi=f"पिछले {n} दिनों", label_hinglish=f"pichhle {n} din",
        )  # fmt: skip
    if m := _MONTH_KEY.match(key):
        year, month = int(m.group(1)), int(m.group(2))
        if not 1 <= month <= 12:
            raise PeriodError("month must be 01..12")
        return _month(key, year, month)
    if m := _YEAR_KEY.match(key):
        return _year(key, int(m.group(1)))
    if m := _RANGE_KEY.match(key):
        start, end = date.fromisoformat(m.group(1)), date.fromisoformat(m.group(2))
        if end < start:
            raise PeriodError("the period ends before it starts")
        return _range(start, end)
    raise PeriodError(f"unknown period: {key}")


def month_keys(period: Period) -> list[str]:
    """Every "YYYY-MM" the period touches, in order."""
    keys: list[str] = []
    year, month = period.start.year, period.start.month
    while (year, month) <= (period.end.year, period.end.month):
        keys.append(f"{year:04d}-{month:02d}")
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    return keys
