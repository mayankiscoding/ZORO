"""Time source. Inject a `Clock` instead of calling `datetime.now()` so expiry logic is testable."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Protocol, runtime_checkable


@runtime_checkable
class Clock(Protocol):
    def now(self) -> datetime:
        """Timezone-aware UTC time."""
        ...


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(UTC)


class FixedClock:
    """A clock that only moves when told to. For tests and deterministic replays."""

    def __init__(self, start: datetime | None = None) -> None:
        current = start or datetime(2026, 1, 1, 12, 0, 0, tzinfo=UTC)
        if current.tzinfo is None:
            raise ValueError("FixedClock needs a timezone-aware datetime")
        self._now = current.astimezone(UTC)

    def now(self) -> datetime:
        return self._now

    def advance(self, seconds: float = 0, *, delta: timedelta | None = None) -> datetime:
        self._now += delta if delta is not None else timedelta(seconds=seconds)
        return self._now

    def set(self, moment: datetime) -> None:
        if moment.tzinfo is None:
            raise ValueError("FixedClock needs a timezone-aware datetime")
        self._now = moment.astimezone(UTC)
