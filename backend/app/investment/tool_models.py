"""Typed inputs and outputs of the investment tools."""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Literal

from pydantic import Field, field_validator

from app.investment.schemas import NOT_ADVICE, Exchange, Product, Side, UnusualMovement, normalise_symbol
from app.investment.strategies import StrategyName
from app.schemas.common import ZModel


class _Symbol(ZModel):
    symbol: str
    exchange: Exchange = "NSE"

    @field_validator("symbol")
    @classmethod
    def _symbol(cls, value: str) -> str:
        return normalise_symbol(value)


class PortfolioSummaryIn(ZModel):
    pass


class UnusualMovementsIn(ZModel):
    scope: Literal["holdings", "watchlist", "all"] = "all"
    symbols: list[str] = Field(default_factory=list, max_length=50)
    lookback_bars: int = Field(default=1, ge=1, le=20)

    @field_validator("symbols")
    @classmethod
    def _symbols(cls, value: list[str]) -> list[str]:
        return [normalise_symbol(s) for s in value]


class UnusualMovementsOut(ZModel):
    movements: list[UnusualMovement]
    checked: int
    missing_data: list[str]
    return_z_threshold: Decimal
    volume_z_threshold: Decimal
    window: int
    disclaimer: str = NOT_ADVICE


class StockAnalysisIn(_Symbol):
    benchmark: str | None = None
    interpret: bool = False  # ask a model for a narrative (only if financial data may reach one)


class TechnicalSnapshotIn(_Symbol):
    pass


class BacktestIn(_Symbol):
    strategy: StrategyName = "sma_crossover"
    params: dict[str, float] = Field(default_factory=dict, max_length=5)
    start: date | None = None
    end: date | None = None
    initial_capital: Decimal = Field(default=Decimal(100_000), gt=0, le=Decimal(10**10))
    slippage_bps: Decimal = Field(default=Decimal(5), ge=0, le=500)
    product: Product = "delivery"


class WatchlistViewIn(ZModel):
    list_name: str = Field(default="default", min_length=1, max_length=40)


class WatchItemView(ZModel):
    symbol: str
    exchange: Exchange
    note: str
    added_at: datetime
    last_close: Decimal | None = None
    close_day: date | None = None
    change_percent: Decimal | None = None
    price_source: str | None = None


class WatchlistOut(ZModel):
    list_name: str
    items: list[WatchItemView]


class WatchlistAddIn(_Symbol):
    note: str = Field(default="", max_length=200)
    list_name: str = Field(default="default", min_length=1, max_length=40)


class WatchlistAddOut(ZModel):
    symbol: str
    exchange: Exchange
    list_name: str
    added: bool
    size: int


class PaperTradeIn(_Symbol):
    side: Side
    quantity: int = Field(ge=1, le=1_000_000)
    product: Product = "delivery"
    slippage_bps: Decimal = Field(default=Decimal(5), ge=0, le=500)
