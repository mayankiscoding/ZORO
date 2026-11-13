"""Dates in photo requests: relative and absolute, English / Hindi / Hinglish.

Everything resolves against an injected `today` in the owner's time zone. Photos are in the past, so
"kal" / "कल" means yesterday here (recorded in `assumptions`), a bare weekday is its most recent
occurrence before today, and a month or a day-and-month without a year is the most recent one that is
not in the future. At most one date expression is read; its words are blanked from the remainder so the
rest of the parser never sees them.
"""

from __future__ import annotations

import calendar
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.vision.lexicon import find_phrase, norm


@dataclass(frozen=True)
class DateMatch:
    start: date
    end: date
    label: str
    remaining: str  # the padded text with the date words blanked
    assumptions: tuple[str, ...] = field(default=())


def local_today(now: datetime, tz: str) -> tuple[date, str | None]:
    """The owner's date, and a note when the zone was unknown and Asia/Kolkata was used."""
    try:
        return now.astimezone(ZoneInfo(tz)).date(), None
    except (ZoneInfoNotFoundError, ValueError):
        return now.astimezone(
            ZoneInfo("Asia/Kolkata")
        ).date(), f"Unknown time zone {tz!r}; used Asia/Kolkata."


def _words(raw: str) -> tuple[str, ...]:
    return tuple(norm(w).strip() for w in raw.split("|"))


MONTHS: dict[str, int] = {}
for _n, _raw in enumerate(
    (
        "january|jan|janwari|janvari|जनवरी",
        "february|feb|farvari|farwari|फरवरी",
        "march|मार्च",
        "april|apr|अप्रैल",
        "may|मई",
        "june|jun|जून",
        "july|jul|जुलाई",
        "august|aug|agast|अगस्त",
        "september|sept|sep|sitambar|सितंबर|सितम्बर",
        "october|oct|aktubar|अक्टूबर|अक्तूबर",
        "november|nov|navambar|नवंबर|नवम्बर",
        "december|dec|disambar|दिसंबर|दिसम्बर",
    ),
    start=1,
):
    for _w in _words(_raw):
        MONTHS[_w] = _n
_MONTH_ALT = "|".join(sorted((re.escape(m) for m in MONTHS), key=len, reverse=True))

WEEKDAYS: dict[str, int] = {}
for _n, _raw in enumerate(
    (
        "monday|somvar|somwar|सोमवार",
        "tuesday|mangalvar|mangalwar|मंगलवार",
        "wednesday|budhvar|budhwar|बुधवार",
        "thursday|guruvar|guruwar|veervar|वीरवार|गुरुवार|बृहस्पतिवार",
        "friday|shukravar|shukrawar|शुक्रवार",
        "saturday|shanivar|shaniwar|शनिवार",
        "sunday|ravivar|raviwar|itwar|रविवार",
    )
):
    for _w in _words(_raw):
        WEEKDAYS[_w] = _n
_WEEKDAY_ALT = "|".join(sorted((re.escape(w) for w in WEEKDAYS), key=len, reverse=True))

NUMBER_WORDS: dict[str, int] = {}
for _value, _raw in (
    (1, "a|an|one|ek|एक"),
    (2, "two|do|दो"),
    (3, "three|teen|तीन"),
    (4, "four|char|chaar|चार"),
    (5, "five|paanch|panch|पांच|पाँच"),
    (6, "six|chhe|छह|छः"),
    (7, "seven|saat|सात"),
    (10, "ten|das|दस"),
):
    for _w in _words(_raw):
        NUMBER_WORDS[_w] = _value
_NUM = r"(?P<n>\d{1,3}|" + "|".join(sorted((re.escape(w) for w in NUMBER_WORDS), key=len, reverse=True)) + ")"
_UNIT_RAW = {
    "day": "day|days|din|dino|दिन|दिनों",
    "week": "week|weeks|hafte|hafta|hafte|हफ्ते|हफ्ता|सप्ताह|हफ़्ते",
    "month": "month|months|mahine|mahina|महीने|महीना|माह",
    "year": "year|years|saal|saalon|साल|वर्ष",
}
_UNITS: dict[str, str] = {w: unit for unit, raw in _UNIT_RAW.items() for w in _words(raw)}
_UNIT_ALT = "|".join(sorted((re.escape(w) for w in _UNITS), key=len, reverse=True))
_LAST = "|".join(_words("last|past|previous|pichhle|pichle|pichhli|pichli|पिछले|पिछली|पिछला"))
_AGO = "|".join(_words("ago|pehle|pahle|पहले"))

PHRASES: dict[str, tuple[str, ...]] = {
    "day_before_yesterday": ("day before yesterday", "parso", "parson", "परसों", "परसो"),
    "yesterday": ("yesterday", "beete kal", "bita hua kal", "kal", "कल"),
    "today": ("today", "aaj", "आज"),
    "last_week": (
        "last week",
        "previous week",
        "pichhle hafte",
        "pichle hafte",
        "pichhla hafta",
        "pichla hafta",
        "पिछले हफ्ते",
        "पिछला हफ्ता",
        "पिछले सप्ताह",
    ),
    "this_week": ("this week", "is hafte", "iss hafte", "इस हफ्ते", "इस सप्ताह"),
    "last_month": (
        "last month",
        "previous month",
        "pichhle mahine",
        "pichle mahine",
        "pichhla mahina",
        "pichla mahina",
        "पिछले महीने",
        "पिछला महीना",
        "पिछले माह",
    ),
    "this_month": ("this month", "is mahine", "iss mahine", "इस महीने", "इस माह"),
    "last_year": (
        "last year",
        "previous year",
        "pichhle saal",
        "pichle saal",
        "pichhla saal",
        "पिछले साल",
        "पिछला साल",
        "पिछले वर्ष",
    ),
    "this_year": ("this year", "is saal", "iss saal", "इस साल", "इस वर्ष"),
    "last_weekend": (
        "last weekend",
        "pichhle weekend",
        "pichle weekend",
        "पिछले वीकेंड",
        "पिछले सप्ताहांत",
        "weekend",
        "वीकेंड",
    ),
}
KAL_NOTE = "'kal' / 'कल' is read as yesterday because photos are in the past."


def _blank(text: str, span: tuple[int, int]) -> str:
    return text[: span[0]] + " " * (span[1] - span[0]) + text[span[1] :]


def _month_range(year: int, month: int) -> tuple[date, date]:
    return date(year, month, 1), date(year, month, calendar.monthrange(year, month)[1])


def _add_months(d: date, months: int) -> date:
    index = d.year * 12 + (d.month - 1) - months
    year, month = divmod(index, 12)
    return date(year, month + 1, min(d.day, calendar.monthrange(year, month + 1)[1]))


def _clamp(start: date, end: date, today: date) -> tuple[date, date]:
    return start, min(end, today)


def _recent_month(month: int, today: date) -> tuple[int, str]:
    year = today.year if date(today.year, month, 1) <= today else today.year - 1
    return year, f"{calendar.month_name[month]} {year}"


def _recent_day(month: int, day: int, today: date) -> date | None:
    for year in (today.year, today.year - 1, today.year - 2):
        try:
            candidate = date(year, month, day)
        except ValueError:
            continue
        if candidate <= today:
            return candidate
    return None


def _number(raw: str) -> int:
    return int(raw) if raw.isdigit() else NUMBER_WORDS[raw]


def _absolute(p: str, today: date) -> DateMatch | None:
    """Numeric dates, then month names. Day first (India): 11/11/2026 is 11 November."""
    if m := re.search(r" (?P<y>20\d{2}) (?P<mo>\d{1,2}) (?P<d>\d{1,2}) ", p):
        try:
            d = date(int(m["y"]), int(m["mo"]), int(m["d"]))
        except ValueError:
            return None
        return DateMatch(d, d, d.isoformat(), _blank(p, m.span()))
    if m := re.search(r" (?P<d>\d{1,2}) (?P<mo>\d{1,2}) (?P<y>20\d{2}) ", p):
        try:
            d = date(int(m["y"]), int(m["mo"]), int(m["d"]))
        except ValueError:
            return None
        return DateMatch(d, d, d.isoformat(), _blank(p, m.span()), ("Numeric dates are read day first.",))
    day_month = re.search(
        rf" (?P<d>\d{{1,2}})(?:st|nd|rd|th)? (?:of )?(?P<m>{_MONTH_ALT})(?: (?P<y>20\d{{2}}))? ", p
    )
    month_day = re.search(rf" (?P<m>{_MONTH_ALT}) (?P<d>\d{{1,2}})(?:st|nd|rd|th)?(?: (?P<y>20\d{{2}}))? ", p)
    month_year = re.search(rf" (?P<m>{_MONTH_ALT}) (?P<y>20\d{{2}}) ", p)
    for m in (day_month, month_day):
        if m is None:
            continue
        month, day = MONTHS[m["m"]], int(m["d"])
        if m["y"]:
            try:
                d = date(int(m["y"]), month, day)
            except ValueError:
                return None
            return DateMatch(d, d, d.isoformat(), _blank(p, m.span()))
        found = _recent_day(month, day, today)
        if found is None:
            return None
        return DateMatch(
            found,
            found,
            found.isoformat(),
            _blank(p, m.span()),
            (f"No year given: used the most recent {day} {calendar.month_name[month]}, {found.year}.",),
        )
    if month_year:
        start, end = _month_range(int(month_year["y"]), MONTHS[month_year["m"]])
        return DateMatch(*_clamp(start, end, today), f"{start:%B %Y}", _blank(p, month_year.span()))
    bare = re.search(rf" (?:(?P<pre>in|during|of|this|last|pichhle|इस|पिछले) )?(?P<m>{_MONTH_ALT}) ", p)
    if bare and ((bare["m"] != "may" and bare["m"] != norm("मई").strip()) or bare["pre"]):
        year, name = _recent_month(MONTHS[bare["m"]], today)
        start, end = _month_range(year, MONTHS[bare["m"]])
        return DateMatch(
            *_clamp(start, end, today),
            name,
            _blank(p, bare.span()),
            (f"No year given: used the most recent {name}.",),
        )
    return None


def _relative(p: str, today: date) -> DateMatch | None:
    if m := re.search(rf" {_NUM} (?P<u>{_UNIT_ALT}) (?:{_AGO}) ", p):
        n, unit = _number(m["n"]), _UNITS[m["u"]]
        if unit == "day":
            d = today - timedelta(days=n)
            return DateMatch(d, d, f"{n} days ago", _blank(p, m.span()))
        if unit == "week":
            anchor = today - timedelta(days=7 * n)
            start = anchor - timedelta(days=anchor.weekday())
            return DateMatch(
                start,
                min(start + timedelta(days=6), today),
                f"{n} weeks ago",
                _blank(p, m.span()),
                ("'weeks ago' is the Monday to Sunday week that long ago.",),
            )
        if unit == "month":
            anchor = _add_months(today, n)
            start, end = _month_range(anchor.year, anchor.month)
            return DateMatch(
                start,
                min(end, today),
                f"{n} months ago",
                _blank(p, m.span()),
                ("'months ago' is the whole calendar month that long ago.",),
            )
        return None
    if m := re.search(rf" (?:{_LAST}) {_NUM} (?P<u>{_UNIT_ALT}) ", p):
        n, unit = _number(m["n"]), _UNITS[m["u"]]
        if n < 1:
            return None
        start = {
            "day": today - timedelta(days=n - 1),
            "week": today - timedelta(days=7 * n - 1),
            "month": _add_months(today, n),
            "year": _add_months(today, 12 * n),
        }[unit]
        return DateMatch(start, today, f"last {n} {unit}s", _blank(p, m.span()))
    return None


def _phrase(p: str, today: date) -> DateMatch | None:
    best: tuple[int, int, str] | None = None
    for key, phrases in PHRASES.items():
        span = find_phrase(p, phrases)
        if span is not None and (
            best is None or (span[0], -(span[1] - span[0])) < (best[0], -(best[1] - best[0]))
        ):
            best = (span[0], span[1], key)
    if best is None:
        return None
    key, span = best[2], (best[0], best[1])
    rest = _blank(p, span)
    if key == "day_before_yesterday":
        d = today - timedelta(days=2)
        return DateMatch(d, d, key, rest, ("'parso' / 'परसों' is read as the day before yesterday.",))
    if key == "yesterday":
        d = today - timedelta(days=1)
        used_kal = any(f" {norm(w).strip()} " in p for w in ("kal", "कल")) and "yesterday" not in p
        return DateMatch(d, d, key, rest, (KAL_NOTE,) if used_kal else ())
    if key == "today":
        return DateMatch(today, today, key, rest)
    if key == "last_week":
        start = today - timedelta(days=today.weekday() + 7)
        return DateMatch(start, start + timedelta(days=6), key, rest)
    if key == "this_week":
        return DateMatch(today - timedelta(days=today.weekday()), today, key, rest)
    if key == "last_month":
        anchor = _add_months(today.replace(day=1), 1)
        start, end = _month_range(anchor.year, anchor.month)
        return DateMatch(start, end, key, rest)
    if key == "this_month":
        return DateMatch(today.replace(day=1), today, key, rest)
    if key == "last_year":
        return DateMatch(date(today.year - 1, 1, 1), date(today.year - 1, 12, 31), key, rest)
    if key == "this_year":
        return DateMatch(date(today.year, 1, 1), today, key, rest)
    sunday = today - timedelta(days=(today.weekday() + 1) % 7 or 7)  # the most recent Sunday before today
    return DateMatch(
        sunday - timedelta(days=1),
        sunday,
        "last_weekend",
        rest,
        ("'weekend' is the Saturday and Sunday of the most recent weekend.",),
    )


def _weekday(p: str, today: date) -> DateMatch | None:
    pre = "|".join(_words("last|on|this|pichhle|is|iss|पिछले|इस|को"))
    m = re.search(rf" (?:(?:{pre}) )?(?P<w>{_WEEKDAY_ALT}) ", p)
    if m is None:
        return None
    back = (today.weekday() - WEEKDAYS[m["w"]]) % 7 or 7
    d = today - timedelta(days=back)
    return DateMatch(
        d,
        d,
        d.strftime("%A").lower(),
        _blank(p, m.span()),
        (f"{d:%A} is read as the most recent {d:%A} before today.",),
    )


def resolve_dates(padded: str, today: date) -> DateMatch | None:
    """Read at most one date expression from normalised, padded text."""
    for step in (_absolute, _relative, _phrase, _weekday):
        found = step(padded, today)
        if found is not None:
            return found
    return None
