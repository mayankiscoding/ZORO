"""Schedule computation for routine triggers, in the routine's own time zone and against an injected time."""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.automation.schemas import DAYS, Trigger


def zone_of(tz: str) -> ZoneInfo:
    try:
        return ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("Asia/Kolkata")


def _at(day: date, hhmm: str, zone: ZoneInfo) -> datetime:
    hour, minute = int(hhmm[:2]), int(hhmm[3:])
    return datetime.combine(day, time(hour, minute), tzinfo=zone).astimezone(UTC)


def next_run_after(trigger: Trigger, after: datetime, tz: str) -> datetime | None:
    """The first run time strictly after `after` (UTC), or None for a manual trigger."""
    if trigger.kind == "manual":
        return None
    after = after.astimezone(UTC)
    zone = zone_of(tz)
    if trigger.kind == "interval":
        assert trigger.every_minutes is not None
        return after + timedelta(minutes=trigger.every_minutes)
    assert trigger.time is not None
    local_day = after.astimezone(zone).date()
    wanted = (
        {DAYS.index(d) for d in trigger.days} if trigger.kind == "weekly" and trigger.days else set(range(7))
    )
    for offset in range(0, 9):
        day = local_day + timedelta(days=offset)
        if day.weekday() not in wanted:
            continue
        candidate = _at(day, trigger.time, zone)
        if candidate > after:
            return candidate
    return None  # unreachable: a weekly trigger always has a day within 8 days
