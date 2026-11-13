"""Fundamentals and news interfaces. No licensed source is configured in this build, so the
defaults report "no_source_configured"; nothing is scraped from exchange or news sites."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Protocol, runtime_checkable

from app.investment.providers.base import ProviderUnavailable
from app.investment.schemas import Instrument
from app.schemas.common import ZModel


class Fundamentals(ZModel):
    instrument: Instrument
    source: str
    as_of: datetime
    pe_ratio: Decimal | None = None
    pb_ratio: Decimal | None = None
    roe_percent: Decimal | None = None
    debt_to_equity: Decimal | None = None
    dividend_yield_percent: Decimal | None = None


class NewsItem(ZModel):
    title: str
    url: str
    published_at: datetime
    source: str
    sentiment: float | None = None  # -1..1 when the source provides one


@runtime_checkable
class FundamentalsSource(Protocol):
    name: str

    async def fundamentals(self, instrument: Instrument) -> Fundamentals: ...


@runtime_checkable
class NewsSource(Protocol):
    name: str

    async def news(self, instrument: Instrument, limit: int = 10) -> list[NewsItem]: ...


class UnconfiguredFundamentals:
    name = "none"

    async def fundamentals(self, instrument: Instrument) -> Fundamentals:
        raise ProviderUnavailable("fundamentals", "no_source_configured", "no licensed fundamentals source")


class UnconfiguredNews:
    name = "none"

    async def news(self, instrument: Instrument, limit: int = 10) -> list[NewsItem]:
        raise ProviderUnavailable("news", "no_source_configured", "no licensed news source")
