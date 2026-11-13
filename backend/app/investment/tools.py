"""Investment tool specs. Risk, data class, permission and allowlist are static.

LOW tools only read (they are not journaled and may re-run). MEDIUM tools write ZORO's own records
(watchlist, paper ledger). The CRITICAL order ticket always needs a biometric approval and only
returns a broker handoff: ZORO never places an order.
"""

from __future__ import annotations

from datetime import date
from typing import Any

from app.core.errors import BadRequest, Unavailable
from app.core.types import AgentId, DataClass, RiskLevel
from app.investment import summaries as s
from app.investment.backtest import BacktestResult, run_backtest
from app.investment.orders import OrderTicket, OrderTicketIn, approval_view, build_ticket
from app.investment.paper import PaperError, PaperTradeOut
from app.investment.research import StockAnalysis
from app.investment.schemas import Instrument, PortfolioSummary, TechnicalSnapshot
from app.investment.services import InvestmentServices, NoPriceData
from app.investment.strategies import build_strategy
from app.investment.tool_models import (
    BacktestIn,
    PaperTradeIn,
    PortfolioSummaryIn,
    StockAnalysisIn,
    TechnicalSnapshotIn,
    UnusualMovementsIn,
    UnusualMovementsOut,
    WatchlistAddIn,
    WatchlistAddOut,
    WatchlistOut,
    WatchlistViewIn,
)
from app.tools.spec import ToolContext, ToolSpec

READ = "investments.read"
WRITE = "investments.write"
ORDER = "investments.order_ticket"
MCP_GROUP = "investment-mcp"
AGENTS = frozenset({AgentId.INVESTMENT})
FINANCIAL = frozenset({DataClass.FINANCIAL})
WORKING_SET = "instruments"


def no_data(exc: NoPriceData) -> Unavailable:
    return Unavailable(f"{exc} Import daily bars (CSV) or connect a broker.", code="no_price_data")


async def _remember(ctx: ToolContext, instruments: list[tuple[str, str]]) -> None:
    await ctx.set_working_set(WORKING_SET, [{"symbol": sym, "exchange": ex} for sym, ex in instruments[:20]])


def build_tools(svc: InvestmentServices) -> list[ToolSpec]:
    async def portfolio_summary(ctx: ToolContext, args: PortfolioSummaryIn) -> PortfolioSummary:
        result = await svc.portfolio.summary(ctx.now())
        await _remember(ctx, [(h.symbol, h.exchange) for h in result.holdings])
        return result

    async def unusual_movements(ctx: ToolContext, args: UnusualMovementsIn) -> UnusualMovementsOut:
        result = await svc.unusual_report(args)
        await _remember(ctx, [(m.symbol, m.exchange) for m in result.movements])
        return result

    async def stock_analysis(ctx: ToolContext, args: StockAnalysisIn) -> StockAnalysis:
        try:
            result = await svc.analyse(
                Instrument(symbol=args.symbol, exchange=args.exchange), ctx.now(),
                benchmark=Instrument(symbol=args.benchmark, exchange=args.exchange) if args.benchmark else None,
                gateway=ctx.gateway, want_interpretation=args.interpret, privacy_mode=ctx.privacy_mode,
                turn_id=ctx.turn_id,
            )  # fmt: skip
        except NoPriceData as exc:
            raise no_data(exc) from exc
        await _remember(ctx, [(args.symbol, args.exchange)])
        return result

    async def technical_snapshot(ctx: ToolContext, args: TechnicalSnapshotIn) -> TechnicalSnapshot:
        try:
            return await svc.technical(Instrument(symbol=args.symbol, exchange=args.exchange))
        except NoPriceData as exc:
            raise no_data(exc) from exc

    async def backtest(ctx: ToolContext, args: BacktestIn) -> BacktestResult:
        try:
            series = await svc.series(Instrument(symbol=args.symbol, exchange=args.exchange), limit=5000)
        except NoPriceData as exc:
            raise no_data(exc) from exc
        start, end = args.start or date.min, args.end or date.max
        series = series.model_copy(update={"candles": [c for c in series.candles if start <= c.day <= end]})
        try:
            return run_backtest(
                series, build_strategy(args.strategy, args.params), svc.config.current(),
                initial_capital=args.initial_capital, slippage_bps=args.slippage_bps, product=args.product,
            )  # fmt: skip
        except ValueError as exc:
            raise BadRequest(str(exc), code="invalid_backtest") from exc

    async def watchlist_view(ctx: ToolContext, args: WatchlistViewIn) -> WatchlistOut:
        result = await svc.watchlist_view(args.list_name)
        await _remember(ctx, [(i.symbol, i.exchange) for i in result.items])
        return result

    async def watchlist_add(ctx: ToolContext, args: WatchlistAddIn) -> WatchlistAddOut:
        return await svc.watchlist_add(args)

    async def paper_trade(ctx: ToolContext, args: PaperTradeIn) -> PaperTradeOut:
        try:
            return await svc.paper.place(
                Instrument(symbol=args.symbol, exchange=args.exchange), args.side, args.quantity,
                product=args.product, slippage_bps=args.slippage_bps, now=ctx.now(),
            )  # fmt: skip
        except PaperError as exc:
            raise BadRequest(str(exc), code=exc.code) from exc

    async def prepare_order_ticket(ctx: ToolContext, args: OrderTicketIn) -> OrderTicket:
        quote = await svc.latest_quote(Instrument(symbol=args.symbol, exchange=args.exchange))
        return build_ticket(args, quote, svc.config.current())

    def spec(name: str, description: str, handler: Any, inp: Any, out: Any, risk: RiskLevel, permission: str,
             summarizer: Any, **extra: Any) -> ToolSpec:  # fmt: skip
        return ToolSpec(
            name=f"investment.{name}", description=description, input_model=inp, output_model=out, handler=handler,
            risk=risk, data_classes=FINANCIAL, permission=permission, agents=AGENTS, mcp_group=MCP_GROUP,
            summarizer=summarizer, **extra,
        )  # fmt: skip

    low = RiskLevel.LOW
    return [
        spec("portfolio_summary", "Value, P&L, allocation, concentration and risk of the owner's holdings.",
             portfolio_summary, PortfolioSummaryIn, PortfolioSummary, low, READ, s.portfolio_summary,
             card=s.portfolio_card),
        spec("unusual_movements", "Stocks whose latest return or volume is unusual against a trailing window.",
             unusual_movements, UnusualMovementsIn, UnusualMovementsOut, low, READ, s.unusual_summary),
        spec("stock_analysis", "Seven-analyst research report on one stock from imported data. Not advice.",
             stock_analysis, StockAnalysisIn, StockAnalysis, low, READ, s.analysis_summary,
             card=s.analysis_card, timeout_s=45),
        spec("technical_snapshot", "Moving averages, RSI, MACD, Bollinger bands, ATR, OBV for one stock.",
             technical_snapshot, TechnicalSnapshotIn, TechnicalSnapshot, low, READ, s.technical_summary),
        spec("backtest", "Backtest a long-only daily strategy with Indian charges, slippage and a tax estimate.",
             backtest, BacktestIn, BacktestResult, low, READ, s.backtest_summary, timeout_s=60),
        spec("watchlist_view", "Show a watchlist with the last imported close of each stock.",
             watchlist_view, WatchlistViewIn, WatchlistOut, low, READ, s.watchlist_summary),
        spec("watchlist_add", "Add a stock to a watchlist.", watchlist_add, WatchlistAddIn, WatchlistAddOut,
             RiskLevel.MEDIUM, WRITE, s.watchlist_add_summary),
        spec("paper_trade", "Record a simulated (paper) trade at the latest real price with Indian charges.",
             paper_trade, PaperTradeIn, PaperTradeOut, RiskLevel.MEDIUM, WRITE, s.paper_summary),
        spec("prepare_order_ticket", "Prepare an order ticket for the owner to place in their broker app. "
             "ZORO never places the order.", prepare_order_ticket, OrderTicketIn, OrderTicket,
             RiskLevel.CRITICAL, ORDER, s.ticket_summary, approval_view=approval_view, rate_limit_per_min=10),
    ]  # fmt: skip
