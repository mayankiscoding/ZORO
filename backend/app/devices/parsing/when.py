"""Deterministic times, dates and durations in English, Hindi and Hinglish.

`parse_when(text, now, tz)` finds at most one date and one time expression and resolves them in the
owner's time zone against an injected `now`. Rules, stated so they can be tested:

- "kal" / "कल" means tomorrow (commands are about the future); this is recorded in `assumptions`.
- A bare weekday is its next occurrence after today ("next" / "agle" changes nothing).
- An hour without AM/PM and without a part of the day is `ambiguous`. With no date it becomes the
  earliest future occurrence; on another day 7-11 is morning, 12 noon and 1-6 afternoon/evening.
- A part of the day alone ("tomorrow evening") uses 09:00 / 14:00 / 18:00 / 21:00 (`assumed_time`).
- "raat 2 baje" on a named day is the early morning after that day.
- Invalid values raise `WhenError` ("25 baje", "13 pm", "31 February"); no expression gives None.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.devices.parsing.lexicon import (
    AFTER_WORDS,
    AMBIGUOUS_DAY_WORDS,
    BAJE,
    BEFORE_WORDS,
    DAY_OFFSETS,
    DEFAULT_HOUR,
    MONTHS,
    NEXT_WORDS,
    NUMBERS,
    PARTS_OF_DAY,
    PREFIX_FRACTIONS,
    STANDALONE_FRACTIONS,
    UNITS,
    WEEKDAYS,
    L,
    R,
    alt,
    lookup,
    norm,
)

Span = tuple[int, int]


class WhenError(ValueError):
    def __init__(self, code: str, message: str, spans: tuple[Span, ...] = ()) -> None:
        super().__init__(message)
        self.code = code  # invalid_time | invalid_date | time_in_past | invalid_timezone
        self.spans = spans  # where the offending expression is, when known


@dataclass(frozen=True)
class When:
    at: datetime  # aware, in the owner's time zone
    has_date: bool
    has_time: bool
    relative: bool = False
    ambiguous: bool = False
    assumed_time: bool = False
    assumptions: tuple[str, ...] = ()
    spans: tuple[Span, ...] = ()

    @property
    def hhmm(self) -> str:
        return self.at.strftime("%H:%M")


@dataclass(frozen=True)
class Duration:
    seconds: int
    spans: tuple[Span, ...] = field(default=())


# ---------------------------------------------------------------- patterns

_NUMBER = rf"(?:\d+(?:\.\d+)?|{alt(NUMBERS)})"
_QTY = (
    rf"(?:(?P<pre>{alt(PREFIX_FRACTIONS)})\s+(?P<num>{_NUMBER})"
    rf"|(?P<num2>{_NUMBER})|(?P<frac>{alt(STANDALONE_FRACTIONS)}))"
)
_TERM = re.compile(rf"{L}{_QTY}\s*(?P<unit>{alt(UNITS)}){R}")
_JOIN = re.compile(r"^\s*(?:,|and|aur|और)?\s*$")
_BEFORE = re.compile(rf"{L}{alt(BEFORE_WORDS)}\s+$")
_AFTER = re.compile(rf"^\s*{alt(AFTER_WORDS)}{R}")

_HOURWORD = rf"(?:\d{{1,2}}|{alt(NUMBERS)})"
_AMPM = re.compile(rf"{L}(?P<h>\d{{1,2}})(?:[:.](?P<m>\d{{2}}))?\s*(?P<ap>a\.?\s?m\.?|p\.?\s?m\.?)(?![\w])")
_BAJE_FRAC = re.compile(rf"{L}(?P<frac>dedh|derh|डेढ़|dhai|dhaai|ढाई)\s*{alt(BAJE)}{R}")
_BAJE = re.compile(
    rf"{L}(?:(?P<pre>{alt(PREFIX_FRACTIONS)})\s+)?(?P<h>{_HOURWORD})(?:[:.](?P<m>\d{{2}}))?\s*{alt(BAJE)}{R}"
)
_CLOCK = re.compile(rf"{L}(?P<h>\d{{1,2}}):(?P<m>\d{{2}}){R}")
_NOON = re.compile(rf"{L}(?P<w>noon|midday|midnight|aadhi\s+raat|आधी\s+रात){R}")
_AT = re.compile(rf"{L}(?:at|by|@)\s+(?P<h>\d{{1,2}}){R}(?!\s*(?:%|{alt(UNITS)}{R}))")
_POD = re.compile(rf"{L}(?P<pod>{alt(PARTS_OF_DAY)}){R}")
_DAY = re.compile(rf"{L}(?P<d>{alt(DAY_OFFSETS)}){R}")
_WEEKDAY = re.compile(rf"{L}(?:{alt(NEXT_WORDS)}\s+)?(?P<wd>{alt(WEEKDAYS)}){R}")
_DATE_DM = re.compile(
    rf"{L}(?P<d>\d{{1,2}})(?:st|nd|rd|th)?\s+(?P<mon>{alt(MONTHS)}){R}(?:,?\s+(?P<y>\d{{4}}){R})?"
)
_DATE_MD = re.compile(
    rf"{L}(?P<mon>{alt(MONTHS)})\s+(?P<d>\d{{1,2}})(?:st|nd|rd|th)?{R}(?:,?\s+(?P<y>\d{{4}}){R})?"
)


_POD_TABLE = {norm(k): v for k, v in PARTS_OF_DAY.items()}


def _number(word: str) -> float:
    value = lookup(NUMBERS, word)
    return float(value) if value is not None else float(word)


def _qty(m: re.Match[str]) -> float:
    if m.group("pre"):
        base = _number(m.group("num"))
        return base + float(lookup(PREFIX_FRACTIONS, m.group("pre")) or 0)
    if m.group("num2"):
        return _number(m.group("num2"))
    return float(lookup(STANDALONE_FRACTIONS, m.group("frac")) or 0)


# ---------------------------------------------------------------- durations


def parse_duration(text: str) -> Duration | None:
    """ "1 hour 30 minutes", "dedh ghanta", "पांच मिनट", "half an hour" -> seconds (first group)."""
    t = norm(text)
    terms = list(_TERM.finditer(t))
    if not terms:
        return None
    group = [terms[0]]
    for term in terms[1:]:
        if not _JOIN.match(t[group[-1].end() : term.start()]):
            break
        group.append(term)
    total = sum(_qty(m) * int(lookup(UNITS, m.group("unit")) or 0) for m in group)
    if total <= 0:
        return None
    return Duration(round(total), ((group[0].start(), group[-1].end()),))


def _relative(t: str) -> Duration | None:
    found = parse_duration(t)
    if found is None:
        return None
    start, end = found.spans[0]
    before = _BEFORE.search(t[:start])
    after = _AFTER.match(t[end:])
    if before is None and after is None:
        return None
    span = (before.start() if before else start, end + (after.end() if after else 0))
    return Duration(found.seconds, (span,))


# ---------------------------------------------------------------- times


@dataclass(frozen=True)
class _Clock:
    hour: int
    minute: int
    explicit: bool  # AM/PM known (am/pm, 24-hour form, noon, midnight)
    span: Span


def _check(hour: int, minute: int) -> None:
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise WhenError("invalid_time", "That is not a valid time.")


def _find_clock(t: str) -> _Clock | None:
    if m := _AMPM.search(t):
        hour, minute = int(m.group("h")), int(m.group("m") or 0)
        if not 1 <= hour <= 12:
            raise WhenError("invalid_time", "With AM or PM the hour must be 1 to 12.")
        _check(hour, minute)
        pm = m.group("ap").startswith("p")
        return _Clock(hour % 12 + (12 if pm else 0), minute, True, m.span())
    if m := _BAJE_FRAC.search(t):
        value = float(lookup(STANDALONE_FRACTIONS, m.group("frac")) or 0)
        return _Clock(int(value), round((value % 1) * 60), False, m.span())
    if m := _BAJE.search(t):
        hour = int(_number(m.group("h")))
        minute = int(m.group("m") or 0)
        if m.group("pre") and not m.group("m"):
            fraction = float(lookup(PREFIX_FRACTIONS, m.group("pre")) or 0)
            total = hour * 60 + round(fraction * 60)
            hour, minute = divmod(total, 60)
        _check(hour, minute)
        return _Clock(hour, minute, hour == 0 or hour > 12, m.span())
    if m := _CLOCK.search(t):
        hour, minute = int(m.group("h")), int(m.group("m"))
        _check(hour, minute)
        leading_zero = m.group("h").startswith("0") and len(m.group("h")) == 2
        return _Clock(hour, minute, hour == 0 or hour > 12 or leading_zero, m.span())
    if m := _NOON.search(t):
        word = m.group("w")
        return _Clock(12 if word in ("noon", "midday") else 0, 0, True, m.span())
    if m := _AT.search(t):
        hour = int(m.group("h"))
        _check(hour, 0)
        return _Clock(hour, 0, hour == 0 or hour > 12, m.span())
    return None


def _with_part_of_day(hour: int, pod: str) -> tuple[int, bool]:
    """(24-hour value, belongs to the early morning after the named day)."""
    if not 1 <= hour <= 12:
        return hour, False
    if pod == "morning":
        return hour % 12, False
    if pod == "afternoon":
        return (hour + 12 if hour <= 6 else hour), False
    if pod == "evening":
        return hour % 12 + 12, False
    if 6 <= hour <= 11:  # night
        return hour + 12, False
    return hour % 12, True  # "raat 12 / 2 baje": after midnight


# ---------------------------------------------------------------- dates


@dataclass(frozen=True)
class _Date:
    day: date
    span: Span
    note: str | None = None


def _find_date(t: str, today: date) -> _Date | None:
    found: list[_Date] = []
    if m := _DAY.search(t):
        word = m.group("d")
        note = "kal_means_tomorrow" if re.sub(r"\s+", " ", word) in AMBIGUOUS_DAY_WORDS else None
        found.append(_Date(today + timedelta(days=int(lookup(DAY_OFFSETS, word) or 0)), m.span(), note))
    if m := _WEEKDAY.search(t):
        ahead = (int(lookup(WEEKDAYS, m.group("wd")) or 0) - today.weekday()) % 7 or 7
        found.append(_Date(today + timedelta(days=ahead), m.span()))
    for pattern in (_DATE_DM, _DATE_MD):
        if m := pattern.search(t):
            month = int(lookup(MONTHS, m.group("mon")) or 0)
            year = int(m.group("y")) if m.group("y") else today.year
            try:
                day = date(year, month, int(m.group("d")))
            except ValueError:
                raise WhenError("invalid_date", "That date does not exist.") from None
            if not m.group("y") and day < today:
                try:
                    day = day.replace(year=year + 1)
                except ValueError:
                    raise WhenError("invalid_date", "That date does not exist.") from None
            found.append(_Date(day, m.span()))
    return min(found, key=lambda d: d.span[0]) if found else None


# ---------------------------------------------------------------- resolution


def _first_span(t: str) -> tuple[Span, ...]:
    """Where a time-like expression starts and ends (for errors), so it can be kept out of titles."""
    for pattern in (_AMPM, _BAJE, _CLOCK, _AT, _DATE_DM, _DATE_MD):
        if m := pattern.search(t):
            return (m.span(),)
    return ()


def zone(tz: str) -> ZoneInfo:
    try:
        return ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError):
        raise WhenError("invalid_timezone", f"Unknown time zone {tz!r}.") from None


def parse_when(text: str, now: datetime, tz: str = "Asia/Kolkata") -> When | None:
    zone_info = zone(tz)
    local_now = now.astimezone(zone_info)
    t = norm(text)

    rel = _relative(t)
    if rel is not None:
        return When(local_now + timedelta(seconds=rel.seconds), True, True, relative=True, spans=rel.spans)

    try:
        clock = _find_clock(t)
    except WhenError as exc:
        raise WhenError(exc.code, str(exc), _first_span(t)) from None
    pod_match = next(
        (
            m
            for m in _POD.finditer(t)
            if clock is None or not (m.start() < clock.span[1] and clock.span[0] < m.end())
        ),
        None,
    )
    pod = _POD_TABLE.get(pod_match.group("pod")) if pod_match else None
    try:
        found = _find_date(t, local_now.date())
    except WhenError as exc:
        raise WhenError(exc.code, str(exc), _first_span(t)) from None
    if found is None and pod_match is not None and pod_match.group("pod") == "tonight":
        found = _Date(local_now.date(), pod_match.span())
    if clock is None and pod is None and found is None:
        return None

    spans = tuple(s for s in (clock.span if clock else None, pod_match.span() if pod_match else None,
                              found.span if found else None) if s is not None)  # fmt: skip
    notes = (found.note,) if found and found.note else ()
    has_date = found is not None
    base = found.day if found else local_now.date()

    def at(day: date, hour: int, minute: int) -> datetime:
        return datetime.combine(day, time(hour, minute), tzinfo=zone_info)

    if clock is None:
        hour = DEFAULT_HOUR[pod] if pod else 9
        moment = at(base, hour, 0)
        if not has_date and moment <= local_now:
            moment += timedelta(days=1)
        return When(moment, has_date, False, assumed_time=True, assumptions=notes, spans=spans)

    if clock.explicit or pod is not None:
        hour, after_midnight = (
            (clock.hour, False) if clock.explicit else _with_part_of_day(clock.hour, pod or "")
        )
        moment = at(base + timedelta(days=1 if after_midnight and has_date else 0), hour, clock.minute)
        if not has_date and moment <= local_now:
            moment += timedelta(days=1)
        if has_date and moment <= local_now:
            raise WhenError("time_in_past", "That time has already passed.", spans)
        return When(moment, has_date, True, assumptions=notes, spans=spans)

    # Ambiguous hour: no AM/PM and no part of the day.
    if not 1 <= clock.hour <= 12:
        raise WhenError("invalid_time", "That is not a valid time.")
    morning, evening = clock.hour % 12, clock.hour % 12 + 12
    if has_date and base != local_now.date():
        hour = morning if clock.hour >= 7 and clock.hour != 12 else (12 if clock.hour == 12 else evening)
        moment = at(base, hour, clock.minute)
    else:
        options = [at(base, h, clock.minute) for h in (morning, evening)]
        if not has_date:
            options.append(at(base + timedelta(days=1), morning, clock.minute))
        future = [o for o in options if o > local_now]
        if not future:
            raise WhenError("time_in_past", "That time has already passed today.", spans)
        moment = min(future)
    return When(moment, has_date, True, ambiguous=True, assumptions=notes, spans=spans)
