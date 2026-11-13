"""Investment tables. Money and prices in integer paise; share quantities in micro-units
(1 share = 1_000_000) so mutual-fund units stay exact; every price row keeps its source and time."""

from __future__ import annotations

from datetime import date, datetime

from sqlalchemy import BigInteger, Date, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime

QTY_SCALE = 1_000_000


class InvHolding(Base):
    __tablename__ = "inv_holdings"
    __table_args__ = (UniqueConstraint("source", "exchange", "symbol", name="source_instrument"),)

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    source: Mapped[str] = mapped_column(String(16))  # csv | kite | dhan
    symbol: Mapped[str] = mapped_column(String(32), index=True)
    exchange: Mapped[str] = mapped_column(String(8))
    isin: Mapped[str | None] = mapped_column(String(12), nullable=True)
    quantity_micro: Mapped[int] = mapped_column(BigInteger)
    avg_price_paise: Mapped[int] = mapped_column(BigInteger)
    last_price_paise: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_as_of: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    imported_at: Mapped[datetime] = mapped_column(UTCDateTime)


class InvPriceBar(Base):
    __tablename__ = "inv_price_bars"
    __table_args__ = (UniqueConstraint("exchange", "symbol", "day", name="instrument_day"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    symbol: Mapped[str] = mapped_column(String(32), index=True)
    exchange: Mapped[str] = mapped_column(String(8))
    day: Mapped[date] = mapped_column(Date)
    open_paise: Mapped[int] = mapped_column(BigInteger)
    high_paise: Mapped[int] = mapped_column(BigInteger)
    low_paise: Mapped[int] = mapped_column(BigInteger)
    close_paise: Mapped[int] = mapped_column(BigInteger)
    volume: Mapped[int] = mapped_column(BigInteger)
    source: Mapped[str] = mapped_column(String(32))
    imported_at: Mapped[datetime] = mapped_column(UTCDateTime)


class InvWatchItem(Base):
    __tablename__ = "inv_watchlist"
    __table_args__ = (UniqueConstraint("list_name", "exchange", "symbol", name="list_instrument"),)

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    list_name: Mapped[str] = mapped_column(String(40), default="default")
    symbol: Mapped[str] = mapped_column(String(32))
    exchange: Mapped[str] = mapped_column(String(8))
    note: Mapped[str] = mapped_column(String(200), default="")
    added_at: Mapped[datetime] = mapped_column(UTCDateTime)


class InvPaperTrade(Base):
    __tablename__ = "inv_paper_trades"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    symbol: Mapped[str] = mapped_column(String(32), index=True)
    exchange: Mapped[str] = mapped_column(String(8))
    side: Mapped[str] = mapped_column(String(4))
    product: Mapped[str] = mapped_column(String(10))
    quantity: Mapped[int] = mapped_column(BigInteger)
    price_paise: Mapped[int] = mapped_column(BigInteger)
    charges_paise: Mapped[int] = mapped_column(BigInteger)
    reference_price_paise: Mapped[int] = mapped_column(BigInteger)
    price_source: Mapped[str] = mapped_column(String(64))
    price_as_of: Mapped[datetime] = mapped_column(UTCDateTime)
    executed_at: Mapped[datetime] = mapped_column(UTCDateTime)


class InvPortfolioSnapshot(Base):
    __tablename__ = "inv_portfolio_snapshots"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    taken_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    value_paise: Mapped[int] = mapped_column(BigInteger)
    invested_paise: Mapped[int] = mapped_column(BigInteger)
    priced_count: Mapped[int] = mapped_column(Integer)
