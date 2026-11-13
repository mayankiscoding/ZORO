"""The owner's own imported files as a provider. Works with no credentials.

Quotes are the last imported daily close, labelled with that session's date: never presented as live.
"""

from __future__ import annotations

from datetime import date

from app.investment.providers.base import ProviderUnavailable
from app.investment.schemas import (
    BrokerHolding,
    BrokerPosition,
    Instrument,
    ProviderStatus,
    Quote,
    Series,
)
from app.investment.store import InvestmentStore

NAME = "csv"


class CsvProvider:
    name = NAME

    def __init__(self, store: InvestmentStore) -> None:
        self._store = store

    async def status(self) -> ProviderStatus:
        return ProviderStatus(
            name=NAME, title="Imported CSV files", status="working", endpoints_verified=True,
            detail="Holdings and daily bars you import. Prices are as of each file's dates.",
        )  # fmt: skip

    async def quotes(self, instruments: list[Instrument]) -> list[Quote]:
        result: list[Quote] = []
        for instrument in instruments:
            bar = await self._store.latest_bar(instrument)
            if bar is not None:
                result.append(
                    Quote(instrument=instrument, last_price=bar.candle.close, as_of=bar.as_of,
                          source=f"csv:{bar.source} (close {bar.candle.day.isoformat()})",
                          volume=bar.candle.volume)
                )  # fmt: skip
        return result

    async def candles(self, instrument: Instrument, start: date, end: date) -> Series:
        series = await self._store.series(instrument)
        if series is None:
            raise ProviderUnavailable(NAME, "no_data", f"no bars imported for {instrument.key}")
        kept = [c for c in series.candles if start <= c.day <= end]
        if not kept:
            raise ProviderUnavailable(NAME, "no_data", f"no bars for {instrument.key} in that range")
        return series.model_copy(update={"candles": kept})

    async def holdings(self) -> list[BrokerHolding]:
        return [
            BrokerHolding(
                instrument=Instrument(symbol=h.symbol, exchange=h.exchange), quantity=h.quantity,
                average_price=h.average_price, last_price=h.last_price, price_as_of=h.price_as_of,
            )
            for h in await self._store.holdings()
            if h.source == NAME
        ]  # fmt: skip

    async def positions(self) -> list[BrokerPosition]:
        return []  # intraday positions are not imported from files
