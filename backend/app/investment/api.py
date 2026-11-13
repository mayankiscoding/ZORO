"""`/v1/investments` routes. Thin: rules live in the services. Device auth on everything and the
same permission grants as the tools. There is deliberately no order route: an order ticket only
comes from the CRITICAL tool, behind a biometric approval."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from decimal import Decimal
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, Form, UploadFile

from app.core.errors import BadRequest, Forbidden, NotFound, Unavailable, ValidationFailed
from app.investment.backtest import BacktestResult, run_backtest
from app.investment.costs import order_charges
from app.investment.csv_import import CsvRejected, parse_bars, parse_holdings
from app.investment.paper import PaperBook, PaperError, PaperTradeOut
from app.investment.providers.base import ProviderUnavailable
from app.investment.providers.kite import KiteAdapter
from app.investment.research import StockAnalysis
from app.investment.schemas import (
    ChargeBreakdown,
    Exchange,
    Instrument,
    PerformancePoint,
    PerformanceReport,
    PortfolioSummary,
    Product,
    ProviderStatus,
    Side,
    TechnicalSnapshot,
)
from app.investment.services import InvestmentServices, NoPriceData
from app.investment.strategies import build_strategy
from app.investment.tool_models import (
    BacktestIn,
    PaperTradeIn,
    UnusualMovementsIn,
    UnusualMovementsOut,
    WatchlistAddIn,
    WatchlistAddOut,
    WatchlistOut,
)
from app.investment.tools import READ, WRITE
from app.schemas.common import ZModel

MAX_UPLOAD_BYTES = 10 * 1024 * 1024


class ImportResult(ZModel):
    imported: int
    updated: int = 0
    source: str


class TokenIn(ZModel):
    access_token: str
    expires_at: datetime | None = None


class KiteSessionIn(ZModel):
    request_token: str


class SessionOut(ZModel):
    provider: str
    expires_at: datetime | None


class ChargesIn(ZModel):
    side: Side
    quantity: int
    price: Decimal
    product: Product = "delivery"
    exchange: Exchange = "NSE"


def _unavailable(exc: ProviderUnavailable) -> Unavailable:
    return Unavailable(f"{exc.provider} is unavailable: {exc.reason}.", code=f"provider_{exc.reason}")


async def _read(upload: UploadFile) -> str:
    raw = await upload.read(MAX_UPLOAD_BYTES + 1)
    if len(raw) > MAX_UPLOAD_BYTES:
        raise BadRequest("CSV files up to 10 MB are accepted.", code="payload_too_large")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise BadRequest("The CSV must be UTF-8 text.", code="csv_invalid") from exc


def _rejected(exc: CsvRejected) -> ValidationFailed:
    return ValidationFailed(
        "The CSV has invalid rows; nothing was imported.", code="csv_invalid",
        detail={"errors": [{"line": e.line, "message": e.message} for e in exc.errors]},
    )  # fmt: skip


def build_router(
    reg: Any, svc: InvestmentServices, require_device: Callable[..., Awaitable[Any]]
) -> APIRouter:
    router = APIRouter(prefix="/investments", tags=["investments"], dependencies=[Depends(require_device)])

    def grant(key: str) -> Callable[[], Awaitable[None]]:
        async def check() -> None:
            if not await reg.service("permissions").is_granted(key):
                raise Forbidden(
                    f"Allow '{key}' in Security and privacy first.", code=f"permission_not_granted:{key}"
                )

        return check

    can_read = [Depends(grant(READ))]
    can_write = [Depends(grant(WRITE))]

    def now() -> datetime:
        clock = reg.service("clock")
        moment: datetime = clock.now()
        return moment.astimezone(UTC)

    # ------------------------------------------------------------ providers

    @router.get("/providers", dependencies=can_read)
    async def providers() -> list[ProviderStatus]:
        return await svc.provider_statuses()

    @router.put("/providers/dhan/token", dependencies=can_write)
    async def dhan_token(body: TokenIn) -> SessionOut:
        if not body.access_token.strip():
            raise BadRequest("access_token is empty.")
        await reg.service("secrets").put("dhan", body.access_token.strip(), expires_at=body.expires_at)
        return SessionOut(provider="dhan", expires_at=body.expires_at)

    @router.post("/providers/kite/session", dependencies=can_write)
    async def kite_session(body: KiteSessionIn) -> SessionOut:
        try:
            kite = svc.brokers.get("kite")
            if not isinstance(kite, KiteAdapter):
                raise NotFound("Kite is not configured.")
            expires = await kite.create_session(body.request_token.strip())
        except ProviderUnavailable as exc:
            raise _unavailable(exc) from exc
        return SessionOut(provider="kite", expires_at=expires)

    @router.post("/providers/{name}/sync", dependencies=can_write)
    async def sync(name: str) -> ImportResult:
        try:
            holdings = await svc.broker(name).holdings()
        except ProviderUnavailable as exc:
            raise _unavailable(exc) from exc
        return ImportResult(imported=await svc.store.replace_holdings(name, holdings), source=name)

    # ------------------------------------------------------------ imports

    @router.post("/holdings/import", dependencies=can_write)
    async def import_holdings(
        file: Annotated[UploadFile, File()], exchange: Annotated[str, Form()] = "NSE"
    ) -> ImportResult:
        try:
            holdings = parse_holdings(await _read(file), default_exchange=exchange.upper())
        except CsvRejected as exc:
            raise _rejected(exc) from exc
        return ImportResult(imported=await svc.store.replace_holdings("csv", holdings), source="csv")

    @router.post("/bars/import", dependencies=can_write)
    async def import_bars(
        file: Annotated[UploadFile, File()],
        symbol: Annotated[str, Form()],
        exchange: Annotated[str, Form()] = "NSE",
    ) -> ImportResult:
        try:
            instrument = Instrument(symbol=symbol, exchange=exchange.upper())
        except ValueError as exc:
            raise BadRequest("symbol or exchange is not valid.", code="invalid_instrument") from exc
        try:
            candles = parse_bars(await _read(file))
        except CsvRejected as exc:
            raise _rejected(exc) from exc
        name = (file.filename or "upload.csv")[:24]
        inserted, updated = await svc.store.upsert_bars(instrument, candles, source=f"file:{name}")
        return ImportResult(imported=inserted, updated=updated, source=f"file:{name}")

    # ------------------------------------------------------------ portfolio

    @router.get("/portfolio", dependencies=can_read)
    async def portfolio() -> PortfolioSummary:
        return await svc.portfolio.summary(now())

    @router.post("/portfolio/snapshots", dependencies=can_write)
    async def snapshot() -> PerformancePoint:
        return await svc.portfolio.snapshot(now())

    @router.get("/portfolio/performance", dependencies=can_read)
    async def performance() -> PerformanceReport:
        return await svc.portfolio.performance()

    @router.get("/unusual-movements", dependencies=can_read)
    async def unusual(scope: str = "all", lookback_bars: int = 1) -> UnusualMovementsOut:
        try:
            args = UnusualMovementsIn(scope=scope, lookback_bars=lookback_bars)
        except ValueError as exc:
            raise BadRequest("scope or lookback_bars is not valid.") from exc
        return await svc.unusual_report(args)

    # ------------------------------------------------------------ watchlists

    @router.get("/watchlists", dependencies=can_read)
    async def watchlists() -> list[str]:
        return await svc.store.watchlist_names()

    @router.get("/watchlists/{name}", dependencies=can_read)
    async def watchlist(name: str) -> WatchlistOut:
        return await svc.watchlist_view(name)

    @router.post("/watchlists/{name}/items", dependencies=can_write)
    async def watchlist_add(name: str, body: WatchlistAddIn) -> WatchlistAddOut:
        return await svc.watchlist_add(body.model_copy(update={"list_name": name}))

    @router.delete("/watchlists/{name}/items/{exchange}/{symbol}", dependencies=can_write)
    async def watchlist_remove(name: str, exchange: str, symbol: str) -> dict[str, bool]:
        try:
            instrument = Instrument(symbol=symbol, exchange=exchange.upper())
        except ValueError as exc:
            raise BadRequest("symbol or exchange is not valid.", code="invalid_instrument") from exc
        if not await svc.store.watchlist_remove(instrument, name):
            raise NotFound(f"{instrument.key} is not on {name}.")
        return {"removed": True}

    # ------------------------------------------------------------ research

    def instrument_of(symbol: str, exchange: str) -> Instrument:
        try:
            return Instrument(symbol=symbol, exchange=exchange.upper())
        except ValueError as exc:
            raise BadRequest("symbol or exchange is not valid.", code="invalid_instrument") from exc

    @router.get("/analysis/{symbol}", dependencies=can_read)
    async def analysis(symbol: str, exchange: str = "NSE", benchmark: str | None = None) -> StockAnalysis:
        try:
            return await svc.analyse(
                instrument_of(symbol, exchange), now(),
                benchmark=instrument_of(benchmark, exchange) if benchmark else None,
            )  # fmt: skip
        except NoPriceData as exc:
            raise Unavailable(str(exc), code="no_price_data") from exc

    @router.get("/technical/{symbol}", dependencies=can_read)
    async def technical(symbol: str, exchange: str = "NSE") -> TechnicalSnapshot:
        try:
            return await svc.technical(instrument_of(symbol, exchange))
        except NoPriceData as exc:
            raise Unavailable(str(exc), code="no_price_data") from exc

    @router.post("/backtests", dependencies=can_read)
    async def backtest(body: BacktestIn, include_curve: bool = False) -> BacktestResult:
        try:
            series = await svc.series(Instrument(symbol=body.symbol, exchange=body.exchange), limit=5000)
        except NoPriceData as exc:
            raise Unavailable(str(exc), code="no_price_data") from exc
        kept = [c for c in series.candles if (body.start is None or c.day >= body.start)
                and (body.end is None or c.day <= body.end)]  # fmt: skip
        try:
            return run_backtest(
                series.model_copy(update={"candles": kept}), build_strategy(body.strategy, body.params),
                svc.config.current(), initial_capital=body.initial_capital, slippage_bps=body.slippage_bps,
                product=body.product, include_curve=include_curve,
            )  # fmt: skip
        except ValueError as exc:
            raise BadRequest(str(exc), code="invalid_backtest") from exc

    @router.post("/charges/estimate", dependencies=can_read)
    async def charges(body: ChargesIn) -> ChargeBreakdown:
        try:
            return order_charges(svc.config.current().charges, side=body.side, quantity=body.quantity,
                                 price=body.price, product=body.product, exchange=body.exchange)  # fmt: skip
        except ValueError as exc:
            raise BadRequest(str(exc)) from exc

    # ------------------------------------------------------------ paper trading

    @router.get("/paper-trades", dependencies=can_read)
    async def paper_book() -> PaperBook:
        return await svc.paper.book()

    @router.post("/paper-trades", dependencies=can_write)
    async def paper_trade(body: PaperTradeIn) -> PaperTradeOut:
        try:
            return await svc.paper.place(
                Instrument(symbol=body.symbol, exchange=body.exchange), body.side, body.quantity,
                product=body.product, slippage_bps=body.slippage_bps, now=now(),
            )  # fmt: skip
        except PaperError as exc:
            raise BadRequest(str(exc), code=exc.code) from exc

    return router
