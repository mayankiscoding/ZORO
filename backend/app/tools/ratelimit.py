"""In-memory token-bucket rate limiter (per process; enough for a single-owner server)."""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass


@dataclass
class _Bucket:
    tokens: float
    updated: float


class TokenBucketRateLimiter:
    """Each key gets a bucket of `per_minute` tokens that refills continuously.

    `time_fn` is a monotonic clock in seconds, injectable for tests.
    """

    def __init__(self, time_fn: Callable[[], float] = time.monotonic, *, max_keys: int = 10_000) -> None:
        self._time = time_fn
        self._buckets: dict[str, _Bucket] = {}
        self._max_keys = max_keys

    def allow(self, key: str, per_minute: int) -> bool:
        """Take one token for `key`. False when the bucket is empty."""
        if per_minute <= 0:
            return False
        now = self._time()
        capacity = float(per_minute)
        bucket = self._buckets.get(key)
        if bucket is None:
            if len(self._buckets) >= self._max_keys:
                self._evict(now)
            bucket = _Bucket(tokens=capacity, updated=now)
            self._buckets[key] = bucket
        else:
            elapsed = max(0.0, now - bucket.updated)
            bucket.tokens = min(capacity, bucket.tokens + elapsed * capacity / 60.0)
            bucket.updated = now
        if bucket.tokens >= 1.0:
            bucket.tokens -= 1.0
            return True
        return False

    def reset(self, key: str | None = None) -> None:
        if key is None:
            self._buckets.clear()
        else:
            self._buckets.pop(key, None)

    def _evict(self, now: float) -> None:
        """Drop buckets idle for over two minutes (they are full again anyway)."""
        stale = [key for key, bucket in self._buckets.items() if now - bucket.updated > 120.0]
        for key in stale:
            del self._buckets[key]
        if len(self._buckets) >= self._max_keys:
            self._buckets.clear()
