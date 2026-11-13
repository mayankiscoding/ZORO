"""Database access for the investment package (service ``investment_store``)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.core.clock import Clock
from app.core.money import from_paise, to_paise
from app.db.base import new_id
from app.db.session import SessionFactory
from app.investment.csv_import import MARKET_CLOSE
from app.investment.models import (
    QTY_SCALE,
    InvHolding,
    InvPaperTrade,
    InvPortfolioSnapshot,
    InvPriceBar,
    InvWatchItem,
)
from app.investment.schemas import BrokerHolding, Candle, Exchange, Instrument, Series


@dataclass(frozen=True)
class StoredHolding:
    symbol: str
    exchange: Exchange
    quantity: Decimal
    average_price: Decimal
    last_price: Decimal | None
    price_as_of: datetime | None
    source: str


@dataclass(frozen=True)
class LatestBar:
    candle: Candle
    source: str

    @property
    def as_of(self) -> datetime:
        return datetime.combine(self.candle.day, MARKET_CLOSE).astimezone(UTC)


def qty_to_micro(quantity: Decimal) -> int:
    micro = quantity * QTY_SCALE
    if micro != micro.to_integral_value():
        raise ValueError("quantity has more than 6 decimal places")
    return int(micro)


class InvestmentStore:
    def __init__(self, session_factory: SessionFactory, clock: Clock) -> None:
        self._sf = session_factory
        self._clock = clock

    # ------------------------------------------------------------ holdings

    async def replace_holdings(self, source: str, holdings: list[BrokerHolding]) -> int:
        """The latest import or sync from `source` replaces that source's previous holdings."""
        now = self._clock.now()
        async with self._sf() as session:
            await session.execute(delete(InvHolding).where(InvHolding.source == source))
            for h in holdings:
                session.add(
                    InvHolding(
                        id=new_id("hold"), source=source, symbol=h.instrument.symbol,
                        exchange=h.instrument.exchange, isin=h.isin, quantity_micro=qty_to_micro(h.quantity),
                        avg_price_paise=to_paise(h.average_price),
                        last_price_paise=None if h.last_price is None else to_paise(h.last_price),
                        price_as_of=None if h.last_price is None else (h.price_as_of or now),
                        imported_at=now,
                    )
                )  # fmt: skip
            await session.commit()
        return len(holdings)

    async def holdings(self) -> list[StoredHolding]:
        async with self._sf() as session:
            rows = (await session.scalars(select(InvHolding).order_by(InvHolding.symbol))).all()
        return [
            StoredHolding(
                symbol=r.symbol, exchange=r.exchange,  # type: ignore[arg-type]
                quantity=Decimal(r.quantity_micro) / QTY_SCALE, average_price=from_paise(r.avg_price_paise),
                last_price=None if r.last_price_paise is None else from_paise(r.last_price_paise),
                price_as_of=r.price_as_of, source=r.source,
            )
            for r in rows
        ]  # fmt: skip

    # ------------------------------------------------------------ bars

    async def upsert_bars(
        self, instrument: Instrument, candles: list[Candle], source: str
    ) -> tuple[int, int]:
        now = self._clock.now()
        inserted = updated = 0
        async with self._sf() as session:
            existing = {
                row.day: row
                for row in (
                    await session.scalars(
                        select(InvPriceBar).where(
                            InvPriceBar.symbol == instrument.symbol,
                            InvPriceBar.exchange == instrument.exchange,
                        )
                    )
                ).all()
            }
            for c in candles:
                values = {
                    "open_paise": to_paise(c.open), "high_paise": to_paise(c.high), "low_paise": to_paise(c.low),
                    "close_paise": to_paise(c.close), "volume": c.volume, "source": source, "imported_at": now,
                }  # fmt: skip
                row = existing.get(c.day)
                if row is None:
                    session.add(
                        InvPriceBar(
                            symbol=instrument.symbol, exchange=instrument.exchange, day=c.day, **values
                        )
                    )
                    inserted += 1
                else:
                    for key, value in values.items():
                        setattr(row, key, value)
                    updated += 1
            await session.commit()
        return inserted, updated

    async def series(self, instrument: Instrument, *, limit: int | None = None) -> Series | None:
        stmt = (
            select(InvPriceBar)
            .where(InvPriceBar.symbol == instrument.symbol, InvPriceBar.exchange == instrument.exchange)
            .order_by(InvPriceBar.day.desc())
        )
        if limit is not None:
            stmt = stmt.limit(limit)
        async with self._sf() as session:
            rows = list(reversed((await session.scalars(stmt)).all()))
        if not rows:
            return None
        candles = [
            Candle(day=r.day, open=from_paise(r.open_paise), high=from_paise(r.high_paise),
                   low=from_paise(r.low_paise), close=from_paise(r.close_paise), volume=r.volume)
            for r in rows
        ]  # fmt: skip
        sources = sorted({r.source for r in rows})
        return Series(
            instrument=instrument, candles=candles, source="+".join(sources),
            fetched_at=max(r.imported_at for r in rows),
        )  # fmt: skip

    async def latest_bar(self, instrument: Instrument) -> LatestBar | None:
        series = await self.series(instrument, limit=1)
        return None if series is None else LatestBar(series.candles[-1], series.source)

    async def instruments_with_bars(self) -> list[Instrument]:
        async with self._sf() as session:
            rows = (
                await session.execute(
                    select(InvPriceBar.exchange, InvPriceBar.symbol, func.count())
                    .group_by(InvPriceBar.exchange, InvPriceBar.symbol)
                    .order_by(InvPriceBar.symbol)
                )
            ).all()
        return [Instrument(symbol=s, exchange=e) for e, s, _ in rows]

    # ------------------------------------------------------------ watchlists

    async def watchlist(self, list_name: str = "default") -> list[InvWatchItem]:
        async with self._sf() as session:
            return list(
                (
                    await session.scalars(
                        select(InvWatchItem)
                        .where(InvWatchItem.list_name == list_name)
                        .order_by(InvWatchItem.added_at)
                    )
                ).all()
            )

    async def watchlist_names(self) -> list[str]:
        async with self._sf() as session:
            return sorted(set((await session.scalars(select(InvWatchItem.list_name))).all()))

    async def watchlist_add(self, instrument: Instrument, note: str = "", list_name: str = "default") -> bool:
        """True when added, False when it was already on the list (idempotent)."""
        async with self._sf() as session:
            found = await session.scalar(
                select(InvWatchItem).where(
                    InvWatchItem.list_name == list_name, InvWatchItem.symbol == instrument.symbol,
                    InvWatchItem.exchange == instrument.exchange,
                )
            )  # fmt: skip
            if found is not None:
                return False
            session.add(
                InvWatchItem(id=new_id("watch"), list_name=list_name, symbol=instrument.symbol,
                             exchange=instrument.exchange, note=note[:200], added_at=self._clock.now())
            )  # fmt: skip
            await session.commit()
            return True

    async def watchlist_remove(self, instrument: Instrument, list_name: str = "default") -> bool:
        async with self._sf() as session:
            result = await session.execute(
                delete(InvWatchItem).where(
                    InvWatchItem.list_name == list_name, InvWatchItem.symbol == instrument.symbol,
                    InvWatchItem.exchange == instrument.exchange,
                )
            )  # fmt: skip
            await session.commit()
            return bool(getattr(result, "rowcount", 0))

    # ------------------------------------------------------------ paper trades and snapshots

    async def add_paper_trade(self, trade: InvPaperTrade) -> None:
        async with self._sf() as session:
            session.add(trade)
            await session.commit()

    async def paper_trades(self, symbol: str | None = None) -> list[InvPaperTrade]:
        stmt = select(InvPaperTrade).order_by(InvPaperTrade.executed_at, InvPaperTrade.id)
        if symbol is not None:
            stmt = stmt.where(InvPaperTrade.symbol == symbol)
        async with self._sf() as session:
            return list((await session.scalars(stmt)).all())

    async def add_snapshot(
        self, value: Decimal, invested: Decimal, priced_count: int
    ) -> InvPortfolioSnapshot:
        row = InvPortfolioSnapshot(
            id=new_id("snap"), taken_at=self._clock.now(), value_paise=to_paise(value),
            invested_paise=to_paise(invested), priced_count=priced_count,
        )  # fmt: skip
        async with self._sf() as session:
            session.add(row)
            await session.commit()
        return row

    async def snapshots(self, limit: int = 365) -> list[InvPortfolioSnapshot]:
        async with self._sf() as session:
            rows = (
                await session.scalars(
                    select(InvPortfolioSnapshot).order_by(InvPortfolioSnapshot.taken_at.desc()).limit(limit)
                )
            ).all()
        return list(reversed(rows))
