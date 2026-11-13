"""Investment data types. Money and prices are `Decimal` (decimal strings in JSON); ratios that are
analytics, not money, are floats rounded for display. Every market value carries source and time."""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Literal

from pydantic import Field, field_validator

from app.schemas.common import ZModel

Exchange = Literal["NSE", "BSE"]
Side = Literal["buy", "sell"]
Product = Literal["delivery", "intraday"]
ProviderName = Literal["csv", "kite", "dhan"]

NOT_ADVICE = (
    "This is information from your own data, not investment advice. Past performance does not "
    "predict future returns; markets can fall and you can lose money."
)

_SYMBOL_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789&-_.")


def normalise_symbol(value: str) -> str:
    symbol = value.strip().upper()
    if not symbol or len(symbol) > 32 or not set(symbol) <= _SYMBOL_CHARS:
        raise ValueError("symbol must be 1-32 characters: letters, digits, & - _ .")
    return symbol


class Instrument(ZModel):
    symbol: str
    exchange: Exchange = "NSE"
    security_id: str | None = None  # broker instrument id (Kite instrument_token, Dhan securityId)

    @field_validator("symbol")
    @classmethod
    def _symbol(cls, value: str) -> str:
        return normalise_symbol(value)

    @property
    def key(self) -> str:
        return f"{self.exchange}:{self.symbol}"


class Candle(ZModel):
    day: date
    open: Decimal
    high: Decimal
    low: Decimal
    close: Decimal
    volume: int = 0


class Quote(ZModel):
    instrument: Instrument
    last_price: Decimal
    as_of: datetime
    source: str
    volume: int | None = None


class Series(ZModel):
    """Daily bars of one instrument, oldest first, with where they came from."""

    instrument: Instrument
    candles: list[Candle]
    source: str
    fetched_at: datetime


class BrokerHolding(ZModel):
    instrument: Instrument
    quantity: Decimal
    average_price: Decimal
    last_price: Decimal | None = None
    price_as_of: datetime | None = None
    isin: str | None = None


class BrokerPosition(ZModel):
    instrument: Instrument
    product: str
    quantity: Decimal
    average_price: Decimal
    last_price: Decimal | None = None
    pnl: Decimal | None = None


class ProviderStatus(ZModel):
    name: str
    title: str
    status: Literal["working", "requires_credentials", "token_expired", "unavailable"]
    read_only: bool = True
    detail: str = ""
    endpoints_verified: bool = False
    docs_url: str = ""


# ---------------------------------------------------------------- portfolio


class HoldingView(ZModel):
    symbol: str
    exchange: Exchange
    quantity: Decimal
    average_price: Decimal
    invested: Decimal
    last_price: Decimal | None = None
    price_source: str | None = None
    price_as_of: datetime | None = None
    value: Decimal | None = None
    pnl: Decimal | None = None
    pnl_percent: Decimal | None = None
    weight_percent: Decimal | None = None
    source: str


class RiskExposure(ZModel):
    status: Literal["ok", "unavailable"]
    reason: str = ""
    annual_volatility_percent: float | None = None
    var_1d_percent: float | None = None  # one-day historical VaR of the weighted portfolio
    var_1d_amount: Decimal | None = None
    observations: int = 0


class PortfolioSummary(ZModel):
    as_of: datetime
    holdings: list[HoldingView]
    holdings_count: int
    priced_count: int
    invested: Decimal  # cost of the priced holdings
    value: Decimal
    pnl: Decimal
    pnl_percent: Decimal | None
    hhi: Decimal | None  # Herfindahl-Hirschman index of weights, 0-1
    effective_holdings: Decimal | None
    concentration_flags: list[str]
    top_holding: str | None = None
    top_weight_percent: Decimal | None = None
    risk: RiskExposure
    sources: list[str]
    unpriced: list[str] = Field(default_factory=list)
    disclaimer: str = NOT_ADVICE


class PerformancePoint(ZModel):
    taken_at: datetime
    value: Decimal
    invested: Decimal


class PerformanceReport(ZModel):
    points: list[PerformancePoint]
    change: Decimal | None = None
    change_percent: Decimal | None = None


# ---------------------------------------------------------------- movements and indicators


class UnusualMovement(ZModel):
    symbol: str
    exchange: Exchange
    day: date
    close: Decimal
    return_percent: float
    return_z: float | None
    volume: int
    volume_z: float | None
    reasons: list[str]
    source: str


class TechnicalSnapshot(ZModel):
    symbol: str
    exchange: Exchange
    as_of: date
    source: str
    bars: int
    close: Decimal
    sma_20: float | None = None
    sma_50: float | None = None
    ema_20: float | None = None
    rsi_14: float | None = None
    macd: float | None = None
    macd_signal: float | None = None
    macd_histogram: float | None = None
    bollinger_upper: float | None = None
    bollinger_lower: float | None = None
    atr_14: float | None = None
    obv: float | None = None
    volume_z: float | None = None
    disclaimer: str = NOT_ADVICE


# ---------------------------------------------------------------- costs


class ChargeBreakdown(ZModel):
    product: Product
    side: Side
    exchange: Exchange
    turnover: Decimal
    brokerage: Decimal
    stt: Decimal
    exchange_transaction: Decimal
    sebi_fee: Decimal
    stamp_duty: Decimal
    gst: Decimal
    dp_charge: Decimal
    total: Decimal
    source: str
    verified_on: str


class TaxEstimate(ZModel):
    short_term_gain: Decimal
    long_term_gain: Decimal
    stcg_tax: Decimal
    ltcg_tax: Decimal
    total_tax: Decimal
    is_estimate: bool = True
    basis: str
