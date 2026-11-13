"""The investment service bundle (service ``investment``) shared by tools and routes."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from typing import Any

from app.core.types import PrivacyMode
from app.investment.config import InvestmentConfigSource
from app.investment.movements import detect_unusual, technical_snapshot
from app.investment.paper import PaperLedger
from app.investment.portfolio import PortfolioService
from app.investment.providers.base import BrokerPortfolioProvider, MarketDataProvider, ProviderUnavailable
from app.investment.providers.csv_provider import CsvProvider
from app.investment.providers.sources import (
    FundamentalsSource,
    NewsSource,
    UnconfiguredFundamentals,
    UnconfiguredNews,
)
from app.investment.research import (
    Interpretation,
    StockAnalysis,
    freshness,
    fundamental_analyst,
    interpret,
    news_analyst,
    portfolio_manager,
    quantitative_analyst,
    risk_analyst,
    technical_analyst,
    verification_analyst,
)
from app.investment.schemas import Instrument, ProviderStatus, Quote, TechnicalSnapshot, UnusualMovement
from app.investment.store import InvestmentStore
from app.investment.tool_models import (
    UnusualMovementsIn,
    UnusualMovementsOut,
    WatchItemView,
    WatchlistAddIn,
    WatchlistAddOut,
    WatchlistOut,
)
from app.investment.verify import FactSheet


def _instrument(symbol: str, exchange: str) -> Instrument:
    return Instrument(symbol=symbol, exchange="BSE" if exchange == "BSE" else "NSE")


class NoPriceData(LookupError):
    def __init__(self, instrument: Instrument) -> None:
        super().__init__(f"No daily bars imported for {instrument.key}.")
        self.instrument = instrument


@dataclass
class InvestmentServices:
    store: InvestmentStore
    config: InvestmentConfigSource
    csv: CsvProvider
    brokers: dict[str, Any] = field(default_factory=dict)  # name -> Kite/Dhan adapter
    fundamentals: FundamentalsSource = field(default_factory=UnconfiguredFundamentals)
    news: NewsSource = field(default_factory=UnconfiguredNews)
    portfolio: PortfolioService = field(init=False)
    paper: PaperLedger = field(init=False)

    def __post_init__(self) -> None:
        self.portfolio = PortfolioService(self.store, self.config)
        self.paper = PaperLedger(self.store, self.config, self.latest_quote)

    def market_providers(self) -> list[MarketDataProvider]:
        return [*self.brokers.values(), self.csv]

    def broker(self, name: str) -> BrokerPortfolioProvider:
        if name not in self.brokers:
            raise ProviderUnavailable(name, "not_supported", "unknown provider")
        provider: BrokerPortfolioProvider = self.brokers[name]
        return provider

    async def provider_statuses(self) -> list[ProviderStatus]:
        return [await self.csv.status()] + [await b.status() for _, b in sorted(self.brokers.items())]

    async def latest_quote(self, instrument: Instrument) -> Quote | None:
        """First quote from a working broker adapter, else the last imported close."""
        for provider in self.market_providers():
            try:
                quotes = await provider.quotes([instrument])
            except ProviderUnavailable:
                continue
            if quotes:
                return quotes[0]
        return None

    async def series(self, instrument: Instrument, limit: int = 400) -> Any:
        series = await self.store.series(instrument, limit=limit)
        if series is None:
            raise NoPriceData(instrument)
        return series

    async def technical(self, instrument: Instrument) -> TechnicalSnapshot:
        return technical_snapshot(await self.series(instrument), self.config.current().analytics)

    async def unusual(
        self, instruments: list[Instrument], lookback_bars: int = 1
    ) -> tuple[list[UnusualMovement], list[str]]:
        """(movements, instruments with no data)."""
        cfg = self.config.current().analytics
        found: list[UnusualMovement] = []
        missing: list[str] = []
        for instrument in instruments:
            series = await self.store.series(instrument, limit=cfg.unusual_window + lookback_bars + 5)
            if series is None:
                missing.append(instrument.symbol)
                continue
            found.extend(detect_unusual(series, cfg, lookback_bars=lookback_bars))
        return found, missing

    async def unusual_report(self, args: UnusualMovementsIn) -> UnusualMovementsOut:
        targets: dict[str, Instrument] = {}
        if args.symbols:
            targets = {sym: Instrument(symbol=sym) for sym in args.symbols}
        else:
            if args.scope in ("holdings", "all"):
                for h in await self.store.holdings():
                    targets.setdefault(
                        f"{h.exchange}:{h.symbol}", Instrument(symbol=h.symbol, exchange=h.exchange)
                    )
            if args.scope in ("watchlist", "all"):
                for w in await self.store.watchlist():
                    targets.setdefault(f"{w.exchange}:{w.symbol}", _instrument(w.symbol, w.exchange))
            if args.scope == "all" and not targets:
                targets = {i.key: i for i in await self.store.instruments_with_bars()}
        movements, missing = await self.unusual(list(targets.values()), args.lookback_bars)
        cfg = self.config.current().analytics
        return UnusualMovementsOut(
            movements=movements, checked=len(targets) - len(missing), missing_data=missing,
            return_z_threshold=cfg.unusual_return_z, volume_z_threshold=cfg.unusual_volume_z, window=cfg.unusual_window,
        )  # fmt: skip

    async def watchlist_view(self, list_name: str = "default") -> WatchlistOut:
        items: list[WatchItemView] = []
        for w in await self.store.watchlist(list_name):
            instrument = _instrument(w.symbol, w.exchange)
            view = WatchItemView(
                symbol=w.symbol, exchange=instrument.exchange, note=w.note, added_at=w.added_at
            )
            series = await self.store.series(instrument, limit=2)
            if series is not None:
                last = series.candles[-1]
                view.last_close, view.close_day, view.price_source = (
                    last.close,
                    last.day,
                    f"csv:{series.source}",
                )
                if len(series.candles) == 2:
                    prev = series.candles[0].close
                    view.change_percent = ((last.close / prev - 1) * 100).quantize(Decimal("0.01"))
            items.append(view)
        return WatchlistOut(list_name=list_name, items=items)

    async def watchlist_add(self, args: WatchlistAddIn) -> WatchlistAddOut:
        instrument = Instrument(symbol=args.symbol, exchange=args.exchange)
        added = await self.store.watchlist_add(instrument, args.note, args.list_name)
        size = len(await self.store.watchlist(args.list_name))
        return WatchlistAddOut(
            symbol=args.symbol, exchange=args.exchange, list_name=args.list_name, added=added, size=size
        )

    async def analyse(
        self,
        instrument: Instrument,
        now: datetime,
        *,
        benchmark: Instrument | None = None,
        gateway: Any = None,
        want_interpretation: bool = False,
        privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE,
        turn_id: str | None = None,
    ) -> StockAnalysis:
        series = await self.series(instrument)
        cfg = self.config.current().analytics
        bench = await self.store.series(benchmark, limit=400) if benchmark is not None else None
        summary = await self.portfolio.summary(now)
        holding = next((h for h in summary.holdings
                        if h.symbol == instrument.symbol and h.exchange == instrument.exchange), None)  # fmt: skip
        sheet = FactSheet()
        try:
            fundamentals: Any = await self.fundamentals.fundamentals(instrument)
        except ProviderUnavailable as exc:
            fundamentals = exc
        try:
            news: Any = await self.news.news(instrument)
        except ProviderUnavailable as exc:
            news = exc
        sections = [
            fundamental_analyst(fundamentals, sheet),
            technical_analyst(series, sheet),
            news_analyst(news, sheet),
            quantitative_analyst(series, bench, cfg, sheet),
            risk_analyst(series, holding, sheet),
        ]
        sections.append(portfolio_manager(sheet, holding))
        check, report = verification_analyst(sections, sheet)
        sections.append(check)
        interpretation = Interpretation(status="not_requested")
        if want_interpretation:
            interpretation = await interpret(
                gateway, sheet, sections, privacy_mode=privacy_mode, turn_id=turn_id
            )
        sources = sorted({s for sec in sections if sec.status == "ok" for s in sec.sources})
        return StockAnalysis(
            symbol=instrument.symbol, exchange=instrument.exchange, generated_at=now,
            last_bar=series.candles[-1].day, freshness=freshness(series.candles[-1].day, now),
            data_sources=sources, sections=sections, facts=sheet.facts(), verification=report,
            interpretation=interpretation,
        )  # fmt: skip
