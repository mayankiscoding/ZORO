"""Read-only data provider protocols and their typed failure.

No protocol here has an order method: ZORO never places an order. A missing credential, an expired
token or a provider outage is a `ProviderUnavailable` with a stable reason, never invented data.
"""

from __future__ import annotations

import json
from datetime import date
from decimal import Decimal
from typing import Any, Literal, Protocol, runtime_checkable

import httpx

from app.investment.schemas import BrokerHolding, BrokerPosition, Instrument, ProviderStatus, Quote, Series

UnavailableReason = Literal[
    "requires_credentials",
    "token_expired",
    "provider_down",
    "rate_limited",
    "bad_response",
    "not_supported",
    "no_data",
    "no_source_configured",
]

HTTP_TIMEOUT = httpx.Timeout(10.0, connect=5.0)


class ProviderUnavailable(Exception):
    def __init__(self, provider: str, reason: UnavailableReason, detail: str = "") -> None:
        super().__init__(f"{provider}: {reason}" + (f" ({detail})" if detail else ""))
        self.provider = provider
        self.reason: UnavailableReason = reason
        self.detail = detail


@runtime_checkable
class MarketDataProvider(Protocol):
    name: str

    async def status(self) -> ProviderStatus: ...

    async def quotes(self, instruments: list[Instrument]) -> list[Quote]: ...

    async def candles(self, instrument: Instrument, start: date, end: date) -> Series: ...


@runtime_checkable
class BrokerPortfolioProvider(Protocol):
    name: str

    async def status(self) -> ProviderStatus: ...

    async def holdings(self) -> list[BrokerHolding]: ...

    async def positions(self) -> list[BrokerPosition]: ...


def decimal_json(response: httpx.Response) -> Any:
    """Parse JSON with every non-integer number as `Decimal` (prices never pass through float)."""
    return json.loads(response.text, parse_float=Decimal)


def to_decimal(value: Any) -> Decimal:
    if isinstance(value, Decimal):
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return Decimal(value)
    if isinstance(value, str):
        return Decimal(value)
    raise ValueError("expected a number")


async def send(
    provider: str, client: httpx.AsyncClient, request: httpx.Request, *, expired_statuses: tuple[int, ...]
) -> Any:
    """Send one read-only request; map transport and HTTP failures to `ProviderUnavailable`."""
    if request.method not in ("GET", "POST"):
        raise ProviderUnavailable(provider, "not_supported", request.method)
    try:
        response = await client.send(request)
    except httpx.TimeoutException as exc:
        raise ProviderUnavailable(provider, "provider_down", "timeout") from exc
    except httpx.HTTPError as exc:
        raise ProviderUnavailable(provider, "provider_down", type(exc).__name__) from exc
    if response.status_code in expired_statuses:
        raise ProviderUnavailable(provider, "token_expired", f"HTTP {response.status_code}")
    if response.status_code == 429:
        raise ProviderUnavailable(provider, "rate_limited", "HTTP 429")
    if response.status_code >= 500:
        raise ProviderUnavailable(provider, "provider_down", f"HTTP {response.status_code}")
    if response.status_code >= 400:
        raise ProviderUnavailable(provider, "bad_response", f"HTTP {response.status_code}")
    try:
        return decimal_json(response)
    except ValueError as exc:
        raise ProviderUnavailable(provider, "bad_response", "not JSON") from exc
