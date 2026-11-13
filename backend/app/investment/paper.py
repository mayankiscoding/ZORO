"""Paper-trading ledger: simulated fills at a real reference price, same cost model as backtests.

The reference price is the latest quote from a working read-only provider, else the last imported
daily close, always stored with its source and time. With no price the trade is refused; a price
is never invented. Nothing here talks to a broker's order API.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from datetime import datetime
from decimal import Decimal

from pydantic import Field

from app.core.money import from_paise, round_money, to_paise
from app.db.base import new_id
from app.investment.config import InvestmentConfigSource
from app.investment.costs import order_charges
from app.investment.models import InvPaperTrade
from app.investment.schemas import Exchange, Instrument, Product, Quote, Side
from app.investment.store import InvestmentStore
from app.schemas.common import ZModel

PriceLookup = Callable[[Instrument], Awaitable[Quote | None]]
_BPS = Decimal(10_000)
PAPER_NOTE = "Paper trade only: nothing was sent to any broker."


class PaperError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class PaperTradeOut(ZModel):
    id: str
    symbol: str
    exchange: Exchange
    side: Side
    product: Product
    quantity: int
    price: Decimal
    charges: Decimal
    reference_price: Decimal
    price_source: str
    price_as_of: datetime
    executed_at: datetime
    note: str = PAPER_NOTE


class PaperPosition(ZModel):
    symbol: str
    exchange: Exchange
    quantity: int
    average_cost: Decimal  # per share, buy charges included
    realised_pnl: Decimal  # net of all charges
    charges_paid: Decimal


class PaperBook(ZModel):
    positions: list[PaperPosition]
    trades: list[PaperTradeOut] = Field(default_factory=list)
    realised_pnl: Decimal
    charges_paid: Decimal
    note: str = PAPER_NOTE


def _out(row: InvPaperTrade) -> PaperTradeOut:
    return PaperTradeOut(
        id=row.id, symbol=row.symbol, exchange=row.exchange, side=row.side, product=row.product,
        quantity=row.quantity, price=from_paise(row.price_paise), charges=from_paise(row.charges_paise),
        reference_price=from_paise(row.reference_price_paise), price_source=row.price_source,
        price_as_of=row.price_as_of, executed_at=row.executed_at,
    )  # fmt: skip


def book_from(trades: list[PaperTradeOut]) -> PaperBook:
    """Average-cost positions. Buy charges raise the cost; sell charges reduce the proceeds."""
    state: dict[tuple[str, str], dict[str, Decimal]] = {}
    for t in trades:
        s = state.setdefault((t.exchange, t.symbol), {"qty": Decimal(0), "cost": Decimal(0),
                                                      "pnl": Decimal(0), "fees": Decimal(0)})  # fmt: skip
        s["fees"] += t.charges
        if t.side == "buy":
            s["qty"] += t.quantity
            s["cost"] += t.quantity * t.price + t.charges
        else:
            avg = s["cost"] / s["qty"] if s["qty"] else Decimal(0)
            s["pnl"] += t.quantity * t.price - t.charges - avg * t.quantity
            s["cost"] -= avg * t.quantity
            s["qty"] -= t.quantity
    positions = [
        PaperPosition(
            symbol=sym, exchange=exch, quantity=int(s["qty"]),
            average_cost=round_money(s["cost"] / s["qty"]) if s["qty"] else Decimal("0.00"),
            realised_pnl=round_money(s["pnl"]), charges_paid=round_money(s["fees"]),
        )
        for (exch, sym), s in sorted(state.items())
    ]  # fmt: skip
    return PaperBook(
        positions=positions, trades=trades,
        realised_pnl=round_money(sum((p.realised_pnl for p in positions), Decimal(0))),
        charges_paid=round_money(sum((p.charges_paid for p in positions), Decimal(0))),
    )  # fmt: skip


class PaperLedger:
    def __init__(self, store: InvestmentStore, config: InvestmentConfigSource, price: PriceLookup) -> None:
        self._store = store
        self._config = config
        self._price = price

    async def book(self) -> PaperBook:
        return book_from([_out(r) for r in await self._store.paper_trades()])

    async def place(
        self,
        instrument: Instrument,
        side: Side,
        quantity: int,
        *,
        product: Product = "delivery",
        slippage_bps: Decimal = Decimal(5),
        now: datetime,
    ) -> PaperTradeOut:
        if quantity <= 0:
            raise PaperError("invalid_quantity", "Quantity must be at least one share.")
        if side == "sell":
            held = next(
                (p.quantity for p in (await self.book()).positions
                 if p.symbol == instrument.symbol and p.exchange == instrument.exchange), 0,
            )  # fmt: skip
            if held < quantity:
                raise PaperError(
                    "insufficient_paper_quantity", f"The paper book holds {held} {instrument.symbol}."
                )
        quote = await self._price(instrument)
        if quote is None:
            raise PaperError(
                "price_unavailable", f"No price for {instrument.key}: import daily bars or connect a broker."
            )
        factor = 1 + slippage_bps / _BPS if side == "buy" else 1 - slippage_bps / _BPS
        price = round_money(quote.last_price * factor)
        charges = order_charges(
            self._config.current().charges, side=side, quantity=quantity, price=price, product=product,
            exchange=instrument.exchange,
        )  # fmt: skip
        row = InvPaperTrade(
            id=new_id("paper"), symbol=instrument.symbol, exchange=instrument.exchange, side=side, product=product,
            quantity=quantity, price_paise=to_paise(price), charges_paise=to_paise(charges.total),
            reference_price_paise=to_paise(quote.last_price), price_source=quote.source[:64],
            price_as_of=quote.as_of, executed_at=now,
        )  # fmt: skip
        await self._store.add_paper_trade(row)
        return _out(row)
