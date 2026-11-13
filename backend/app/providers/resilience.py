"""Retry policy with exponential backoff + jitter, and a per-model circuit breaker."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum


@dataclass(frozen=True)
class RetryPolicy:
    max_attempts: int = 2  # per candidate model, before falling back to the next one
    base_delay_s: float = 0.25
    max_delay_s: float = 4.0
    #: A 429 with Retry-After up to this many seconds is waited out on the same model; longer ones
    #: put the model on cooldown and fall back immediately.
    max_retry_after_s: float = 3.0
    default_rate_limit_cooldown_s: float = 30.0

    def backoff(self, attempt: int, rand: float) -> float:
        """Delay before retry number `attempt` (0-based), with jitter in [0.5, 1.5) of the base."""
        return float(min(self.max_delay_s, self.base_delay_s * (2**attempt)) * (0.5 + rand))


class BreakerState(StrEnum):
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"


class CircuitBreaker:
    """closed -> open after `failure_threshold` consecutive failures; open -> half-open after
    `open_seconds`; half-open lets exactly one trial through: success closes, failure re-opens.
    A rate-limit cooldown blocks the model until it expires without counting as a failure."""

    def __init__(
        self, *, failure_threshold: int = 3, open_seconds: float = 30.0, clock: Callable[[], float]
    ) -> None:
        self.failure_threshold = failure_threshold
        self.open_seconds = open_seconds
        self._clock = clock
        self._failures = 0
        self._opened_at: float | None = None
        self._trial_in_flight = False
        self._cooldown_until = 0.0

    @property
    def state(self) -> BreakerState:
        if self._opened_at is None:
            return BreakerState.CLOSED
        if self._clock() - self._opened_at >= self.open_seconds:
            return BreakerState.HALF_OPEN
        return BreakerState.OPEN

    @property
    def cooling_down(self) -> bool:
        return self._clock() < self._cooldown_until

    def available(self) -> bool:
        """Read-only check (for route info): would `allow()` let a call through now?"""
        if self.cooling_down:
            return False
        state = self.state
        return state is BreakerState.CLOSED or (state is BreakerState.HALF_OPEN and not self._trial_in_flight)

    def allow(self) -> bool:
        if not self.available():
            return False
        if self.state is BreakerState.HALF_OPEN:
            self._trial_in_flight = True
        return True

    def record_success(self) -> None:
        self._failures = 0
        self._opened_at = None
        self._trial_in_flight = False

    def record_failure(self) -> None:
        if self.state is BreakerState.HALF_OPEN:
            self._opened_at = self._clock()
            self._trial_in_flight = False
            return
        self._failures += 1
        if self._failures >= self.failure_threshold:
            self._opened_at = self._clock()

    def release(self) -> None:
        """End a half-open trial that neither succeeded nor failed on the provider's side."""
        self._trial_in_flight = False

    def cool_down(self, seconds: float) -> None:
        self._cooldown_until = max(self._cooldown_until, self._clock() + seconds)
        self._trial_in_flight = False
