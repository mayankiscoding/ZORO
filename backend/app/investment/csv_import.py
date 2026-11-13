"""Parse and validate owner-imported CSV files: holdings and daily OHLCV bars.

All-or-nothing: a file with any invalid row is rejected with every problem listed (line numbers
count the header as line 1). Numbers are parsed as `Decimal`, never float.
"""

from __future__ import annotations

import csv
import io
import re
from dataclasses import dataclass, field
from datetime import date, datetime, time
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

from app.investment.schemas import BrokerHolding, Candle, Instrument, normalise_symbol

MAX_ROWS = 20_000
MAX_ERRORS = 50

_HOLDING_ALIASES = {
    "symbol": ("symbol", "tradingsymbol", "instrument", "stock", "scrip"),
    "exchange": ("exchange", "exch"),
    "quantity": ("quantity", "qty", "units", "shares"),
    "avg_price": ("avgprice", "averageprice", "avgcost", "averagecost", "buyprice", "avg"),
    "last_price": ("lastprice", "ltp", "price", "close"),
    "price_date": ("pricedate", "asof", "date"),
    "isin": ("isin",),
}
_BAR_ALIASES = {
    "day": ("date", "day", "timestamp"),
    "open": ("open", "o"),
    "high": ("high", "h"),
    "low": ("low", "l"),
    "close": ("close", "c", "adjclose"),
    "volume": ("volume", "vol", "v", "qty"),
}
_DATE_FORMATS = ("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%d-%b-%Y", "%d %b %Y")
IST = ZoneInfo("Asia/Kolkata")
MARKET_CLOSE = time(15, 30, tzinfo=IST)  # a daily close price is "as of" the session close


@dataclass(frozen=True)
class RowError:
    line: int
    message: str


@dataclass
class ParseResult[T]:
    rows: list[T] = field(default_factory=list)
    errors: list[RowError] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors and bool(self.rows)


class CsvRejected(ValueError):
    def __init__(self, errors: list[RowError]) -> None:
        super().__init__("; ".join(f"line {e.line}: {e.message}" for e in errors[:5]))
        self.errors = errors


def _key(name: str) -> str:
    return re.sub(r"[^a-z]", "", name.lower())


def _columns(header: list[str], aliases: dict[str, tuple[str, ...]]) -> dict[str, int]:
    keys = [_key(h) for h in header]
    found: dict[str, int] = {}
    for field_name, names in aliases.items():
        for alias in names:
            if alias in keys:
                found[field_name] = keys.index(alias)
                break
    return found


def parse_decimal(text: str, what: str) -> Decimal:
    cleaned = text.strip().replace(",", "").replace("₹", "")
    try:
        value = Decimal(cleaned)
    except InvalidOperation:
        raise ValueError(f"{what} is not a number: {text.strip()[:20]!r}") from None
    if not value.is_finite():
        raise ValueError(f"{what} is not a finite number")
    return value


def parse_date(text: str) -> date:
    raw = text.strip()[:19]
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(raw[: len(datetime(2000, 1, 1).strftime(fmt))], fmt).date()
        except ValueError:
            continue
    raise ValueError(f"date not understood: {text.strip()[:20]!r} (use YYYY-MM-DD)")


def _reader(text: str) -> tuple[list[str], list[tuple[int, list[str]]]]:
    rows = list(csv.reader(io.StringIO(text.lstrip("﻿"))))
    if not rows:
        raise CsvRejected([RowError(1, "the file is empty")])
    body = [(i + 2, r) for i, r in enumerate(rows[1:]) if any(cell.strip() for cell in r)]
    if len(body) > MAX_ROWS:
        raise CsvRejected([RowError(1, f"more than {MAX_ROWS} rows")])
    return rows[0], body


def _cell(row: list[str], cols: dict[str, int], name: str) -> str:
    idx = cols.get(name)
    return row[idx].strip() if idx is not None and idx < len(row) else ""


def parse_holdings(text: str, *, default_exchange: str = "NSE") -> list[BrokerHolding]:
    header, body = _reader(text)
    cols = _columns(header, _HOLDING_ALIASES)
    missing = [n for n in ("symbol", "quantity", "avg_price") if n not in cols]
    if missing:
        raise CsvRejected([RowError(1, f"missing column(s): {', '.join(missing)}")])
    result: ParseResult[BrokerHolding] = ParseResult()
    seen: set[str] = set()
    for line, row in body:
        try:
            exchange = (_cell(row, cols, "exchange") or default_exchange).upper()
            if exchange not in ("NSE", "BSE"):
                raise ValueError(f"exchange must be NSE or BSE, got {exchange[:8]!r}")
            symbol = normalise_symbol(_cell(row, cols, "symbol"))
            qty = parse_decimal(_cell(row, cols, "quantity"), "quantity")
            avg = parse_decimal(_cell(row, cols, "avg_price"), "average price")
            if qty <= 0 or avg < 0:
                raise ValueError("quantity must be positive and average price not negative")
            last_text = _cell(row, cols, "last_price")
            last = parse_decimal(last_text, "last price") if last_text else None
            if last is not None and last <= 0:
                raise ValueError("last price must be positive")
            date_text = _cell(row, cols, "price_date")
            as_of = (
                datetime.combine(parse_date(date_text), MARKET_CLOSE)
                if date_text and last is not None
                else None
            )
            key = f"{exchange}:{symbol}"
            if key in seen:
                raise ValueError(f"{key} appears twice")
            seen.add(key)
            isin = _cell(row, cols, "isin").upper() or None
            if isin is not None and not re.fullmatch(r"[A-Z]{2}[A-Z0-9]{9}[0-9]", isin):
                raise ValueError("ISIN is not valid")
            result.rows.append(
                BrokerHolding(
                    instrument=Instrument(symbol=symbol, exchange=exchange),
                    quantity=qty, average_price=avg, last_price=last, price_as_of=as_of, isin=isin,
                )
            )  # fmt: skip
        except ValueError as exc:
            result.errors.append(RowError(line, str(exc).splitlines()[0][:160]))
        if len(result.errors) >= MAX_ERRORS:
            break
    if not result.ok:
        raise CsvRejected(result.errors or [RowError(1, "no rows")])
    return result.rows


def parse_bars(text: str) -> list[Candle]:
    header, body = _reader(text)
    cols = _columns(header, _BAR_ALIASES)
    missing = [n for n in ("day", "open", "high", "low", "close") if n not in cols]
    if missing:
        raise CsvRejected([RowError(1, f"missing column(s): {', '.join(missing)}")])
    result: ParseResult[Candle] = ParseResult()
    seen: set[date] = set()
    for line, row in body:
        try:
            day = parse_date(_cell(row, cols, "day"))
            o, h, lo, c = (parse_decimal(_cell(row, cols, n), n) for n in ("open", "high", "low", "close"))
            vol_text = _cell(row, cols, "volume")
            volume = parse_decimal(vol_text, "volume") if vol_text else Decimal(0)
            if min(o, h, lo, c) <= 0:
                raise ValueError("prices must be positive")
            if h < max(o, c, lo) or lo > min(o, c):
                raise ValueError("high/low do not contain open and close")
            if volume < 0 or volume != volume.to_integral_value():
                raise ValueError("volume must be a whole number, not negative")
            if day in seen:
                raise ValueError(f"{day.isoformat()} appears twice")
            seen.add(day)
            result.rows.append(Candle(day=day, open=o, high=h, low=lo, close=c, volume=int(volume)))
        except ValueError as exc:
            result.errors.append(RowError(line, str(exc).splitlines()[0][:160]))
        if len(result.errors) >= MAX_ERRORS:
            break
    if not result.ok:
        raise CsvRejected(result.errors or [RowError(1, "no rows")])
    return sorted(result.rows, key=lambda candle: candle.day)
