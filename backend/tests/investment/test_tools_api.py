"""Tools through the real executor and policy, intents, and the /v1/investments routes."""

from __future__ import annotations

import json
from datetime import timedelta
from decimal import Decimal

import httpx
from fastapi import FastAPI

from app.core.types import AgentId, ApprovalLevel, DataClass, RiskLevel
from app.investment.config import InvestmentConfig
from app.investment.intents import build_intents
from app.investment.providers.kite import KiteAdapter
from app.investment.schemas import Instrument
from app.investment.services import InvestmentServices
from app.plugins import PluginRegistry
from app.tools import Completed, Denied, Failed, NeedsApproval, ToolExecutor
from app.tools.intents import IntentContext
from tests.conftest import PairedDevice
from tests.investment.conftest import NOW, make_ctx
from tests.investment.samples import HOLDINGS_CSV, bars_csv, random_walk

TOOLS = {
    "investment.portfolio_summary": RiskLevel.LOW, "investment.unusual_movements": RiskLevel.LOW,
    "investment.stock_analysis": RiskLevel.LOW, "investment.technical_snapshot": RiskLevel.LOW,
    "investment.backtest": RiskLevel.LOW, "investment.watchlist_view": RiskLevel.LOW,
    "investment.watchlist_add": RiskLevel.MEDIUM, "investment.paper_trade": RiskLevel.MEDIUM,
    "investment.prepare_order_ticket": RiskLevel.CRITICAL,
}  # fmt: skip


def test_tool_metadata_is_static_and_complete(registry: PluginRegistry) -> None:
    for name, risk in TOOLS.items():
        spec = registry.tools.get(name)
        assert spec is not None and spec.risk is risk, name
        assert spec.data_classes == frozenset({DataClass.FINANCIAL}) and spec.mcp_group == "investment-mcp"
        assert spec.agents == frozenset({AgentId.INVESTMENT}) and spec.summarizer is not None
        expected = {RiskLevel.LOW: "investments.read", RiskLevel.MEDIUM: "investments.write"}.get(
            risk, "investments.order_ticket"
        )
        assert spec.permission == expected
    assert registry.tools.get("investment.prepare_order_ticket").approval_view is not None  # type: ignore[union-attr]
    for intent in build_intents():
        assert set(intent.keywords) == {"en", "hi", "hinglish"} and all(intent.keywords.values())


def test_intents_extract_slots_in_three_languages() -> None:
    ctx = IntentContext(lang="en", now=NOW, working_sets={"instruments": [{"symbol": "INFY", "exchange": "NSE"},
                                                                         {"symbol": "TCS", "exchange": "NSE"}]})  # fmt: skip
    by = {i.name: i for i in build_intents()}
    assert by["investment.portfolio_summary"].extract("check my portfolio", ctx) == {}
    assert by["investment.portfolio_summary"].extract("मेरा पोर्टफोलियो दिखाओ", ctx) == {}
    assert by["investment.portfolio_summary"].extract("mera portfolio dikhao", ctx) == {}
    assert by["investment.portfolio_summary"].extract("play some music", ctx) is None
    assert by["investment.unusual_movements"].extract("any unusual movements today?", ctx) == {}
    assert by["investment.unusual_movements"].extract("शेयरों में असामान्य हलचल", ctx) == {}
    assert by["investment.unusual_movements"].extract("koi bada movement hua kya", ctx) == {}
    assert by["investment.stock_analysis"].extract("analyse RELIANCE", ctx) == {"symbol": "RELIANCE"}
    assert by["investment.stock_analysis"].extract("analyse infy please", ctx) == {"symbol": "INFY"}
    assert by["investment.stock_analysis"].extract("doosra wala ka analysis karo", ctx) == {
        "symbol": "TCS",
        "exchange": "NSE",
    }
    assert by["investment.stock_analysis"].extract("दूसरा वाला का विश्लेषण", ctx) == {
        "symbol": "TCS",
        "exchange": "NSE",
    }
    assert by["investment.watchlist_add"].extract("add INFY to my watchlist", ctx) == {"symbol": "INFY"}
    assert by["investment.watchlist_add"].extract("HDFCBANK को वॉचलिस्ट में जोड़ो", ctx) == {"symbol": "HDFCBANK"}
    assert by["investment.watchlist_add"].extract("what is on my watchlist", ctx) is None


async def _seed(svc: InvestmentServices) -> None:
    from app.investment.csv_import import parse_holdings

    await svc.store.replace_holdings("csv", parse_holdings(HOLDINGS_CSV))
    await svc.store.upsert_bars(Instrument(symbol="WALK"), random_walk(300).candles, "file:walk.csv")


async def test_read_tools_through_the_executor(registry: PluginRegistry, svc: InvestmentServices) -> None:
    await _seed(svc)
    executor: ToolExecutor = registry.service("tool_executor")
    said: dict[str, str] = {}
    for lang in ("en", "hi", "hinglish"):
        done = await executor.execute(
            make_ctx(registry, lang=lang), "investment.portfolio_summary", {}, call_id=f"p_{lang}"
        )
        assert isinstance(done, Completed) and done.summary and done.card is not None
        assert done.card.kind == "portfolio"
        assert str(done.result.priced_count) in done.summary  # type: ignore[attr-defined]
        said[lang] = done.summary
    assert "पोर्टफोलियो" in said["hi"] and "Aapka portfolio" in said["hinglish"] and "worth" in said["en"]
    hi = await executor.execute(
        make_ctx(registry, lang="hi"), "investment.stock_analysis", {"symbol": "walk"}, call_id="a1"
    )
    assert isinstance(hi, Completed) and hi.card is not None and hi.card.kind == "stock_analysis"
    assert "निवेश सलाह नहीं" in (hi.summary or "")
    assert await make_ctx(registry).working_set("instruments") == [{"symbol": "WALK", "exchange": "NSE"}]
    tech = await executor.execute(
        make_ctx(registry), "investment.technical_snapshot", {"symbol": "WALK"}, call_id="t1"
    )
    assert isinstance(tech, Completed) and "WALK closed at ₹" in (tech.summary or "")
    bt = await executor.execute(make_ctx(registry), "investment.backtest",
                                {"symbol": "WALK", "strategy": "momentum", "params": {"lookback": 20}}, call_id="b1")  # fmt: skip
    assert isinstance(bt, Completed) and "do not predict" in (bt.summary or "")
    moves = await executor.execute(make_ctx(registry), "investment.unusual_movements", {}, call_id="u1")
    assert isinstance(moves, Completed) and moves.result.missing_data == ["TESTCO"]  # type: ignore[attr-defined]
    missing = await executor.execute(
        make_ctx(registry), "investment.stock_analysis", {"symbol": "NODATA"}, call_id="a2"
    )
    assert isinstance(missing, Failed) and missing.error == "no_price_data"


async def test_watchlist_and_paper_trades(registry: PluginRegistry, svc: InvestmentServices) -> None:
    await _seed(svc)
    executor: ToolExecutor = registry.service("tool_executor")
    ctx = make_ctx(registry)
    added = await executor.execute(ctx, "investment.watchlist_add", {"symbol": "walk"}, call_id="w1")
    assert isinstance(added, Completed) and added.result.added  # type: ignore[attr-defined]
    again = await executor.execute(ctx, "investment.watchlist_add", {"symbol": "WALK"}, call_id="w2")
    assert isinstance(again, Completed) and not again.result.added  # type: ignore[attr-defined]
    view = await executor.execute(ctx, "investment.watchlist_view", {}, call_id="w3")
    assert isinstance(view, Completed) and view.result.items[0].last_close is not None  # type: ignore[attr-defined]

    buy = await executor.execute(ctx, "investment.paper_trade", {"symbol": "WALK", "side": "buy", "quantity": 10},
                                 call_id="pt1")  # fmt: skip
    assert isinstance(buy, Completed) and "nothing went to a broker" in (buy.summary or "")
    trade = buy.result
    last = await svc.store.latest_bar(Instrument(symbol="WALK"))
    assert last is not None and trade.reference_price == last.candle.close  # type: ignore[attr-defined]
    assert trade.price == (last.candle.close * Decimal("1.0005")).quantize(Decimal("0.01"))  # type: ignore[attr-defined]
    oversell = await executor.execute(ctx, "investment.paper_trade",
                                      {"symbol": "WALK", "side": "sell", "quantity": 11}, call_id="pt2")  # fmt: skip
    assert isinstance(oversell, Failed) and oversell.error == "insufficient_paper_quantity"
    no_price = await executor.execute(ctx, "investment.paper_trade",
                                      {"symbol": "TESTCO", "side": "buy", "quantity": 1}, call_id="pt3")  # fmt: skip
    assert isinstance(no_price, Failed) and no_price.error == "price_unavailable"
    book = await svc.paper.book()
    assert book.positions[0].quantity == 10 and book.charges_paid == trade.charges  # type: ignore[attr-defined]


async def test_order_ticket_always_needs_biometric_and_never_places(
    registry: PluginRegistry, svc: InvestmentServices, paired_device: PairedDevice, cfg: InvestmentConfig
) -> None:
    seen: list[httpx.Request] = []

    def broker(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, text=json.dumps({"status": "success", "data": {
            "NSE:INFY": {"last_price": 1500.5, "last_trade_time": "2026-11-13 11:00:00"}}}))  # fmt: skip

    secrets, clock = registry.service("secrets"), registry.service("clock")
    await secrets.put("kite", "tok", expires_at=clock.now() + timedelta(hours=2))
    svc.brokers["kite"] = KiteAdapter(cfg.providers["kite"], secrets, clock, {"KITE_API_KEY": "k"},
                                      httpx.MockTransport(broker))  # fmt: skip
    executor: ToolExecutor = registry.service("tool_executor")
    args = {"symbol": "INFY", "side": "buy", "quantity": 5, "order_type": "limit", "limit_price": "1490.00"}
    for user_initiated in (True, False):
        ctx = make_ctx(registry, device_id=paired_device.device_id, user_initiated=user_initiated)
        pending = await executor.execute(
            ctx, "investment.prepare_order_ticket", args, call_id=f"o_{user_initiated}"
        )
        assert isinstance(pending, NeedsApproval) and pending.request.level is ApprovalLevel.BIOMETRIC
        assert pending.request.risk is RiskLevel.CRITICAL and "BUY 5 INFY" in pending.request.title
        assert seen == []  # nothing ran before approval
    ctx = make_ctx(registry, device_id=paired_device.device_id, user_initiated=True)
    assert isinstance(pending, NeedsApproval)
    request = pending.request
    auth_key = await executor.resume_with_approval(
        ctx, "o_False", paired_device.signer.sign_approval(request, key="auth")
    )
    assert isinstance(auth_key, Denied)  # a plain tap is not enough for CRITICAL
    pending2 = await executor.execute(ctx, "investment.prepare_order_ticket", args, call_id="o_True")
    assert isinstance(pending2, NeedsApproval)
    done = await executor.resume_with_approval(
        ctx, "o_True", paired_device.signer.sign_approval(pending2.request)
    )
    assert isinstance(done, Completed)
    ticket = done.result
    assert ticket.placed_by_zoro is False and ticket.handoff.url == "https://kite.zerodha.com/"  # type: ignore[attr-defined]
    assert ticket.estimated_value == Decimal("7450.00") and ticket.reference_price == Decimal("1500.5")  # type: ignore[attr-defined]
    assert any("static IP" in r for r in ticket.rules) and any("10 per second" in r for r in ticket.rules)  # type: ignore[attr-defined]
    assert "ZORO did not place it" in (done.summary or "")
    assert [(r.method, r.url.path) for r in seen] == [("GET", "/quote")]  # read-only quote, no order call


async def test_routes_import_validation_and_no_order_route(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry, app: FastAPI
) -> None:
    h = paired_device.headers
    bad = await client.post("/v1/investments/holdings/import", headers=h,
                            files={"file": ("h.csv", "Symbol,Qty,Avg price\nINFY,-3,10\nINFY,abc,10\n,1,1\n")})  # fmt: skip
    assert bad.status_code == 422 and bad.json()["code"] == "csv_invalid"
    assert [e["line"] for e in bad.json()["detail"]["errors"]] == [2, 3, 4]
    missing_col = await client.post(
        "/v1/investments/holdings/import", headers=h, files={"file": ("h.csv", "Symbol\nINFY\n")}
    )
    assert (
        missing_col.status_code == 422
        and "missing column" in missing_col.json()["detail"]["errors"][0]["message"]
    )
    good = await client.post(
        "/v1/investments/holdings/import", headers=h, files={"file": ("h.csv", HOLDINGS_CSV)}
    )
    assert good.status_code == 200 and good.json()["imported"] == 2
    bars = await client.post("/v1/investments/bars/import", headers=h, data={"symbol": "WALK"},
                             files={"file": ("walk.csv", bars_csv(random_walk(80)))})  # fmt: skip
    assert bars.status_code == 200 and bars.json()["imported"] == 80
    broken = await client.post("/v1/investments/bars/import", headers=h, data={"symbol": "WALK"},
                               files={"file": ("b.csv", "Date,Open,High,Low,Close\n2026-01-02,10,9,8,10\n")})  # fmt: skip
    assert broken.status_code == 422 and "high/low" in broken.json()["detail"]["errors"][0]["message"]

    portfolio = (await client.get("/v1/investments/portfolio", headers=h)).json()
    assert portfolio["priced_count"] == 2 and isinstance(portfolio["value"], str)  # money as decimal string
    providers = {p["name"]: p for p in (await client.get("/v1/investments/providers", headers=h)).json()}
    assert providers["csv"]["status"] == "working" and providers["kite"]["read_only"] is True
    charges = await client.post("/v1/investments/charges/estimate", headers=h,
                                json={"side": "buy", "quantity": 100, "price": "1000"})  # fmt: skip
    assert charges.json()["total"] == "118.74"
    sync = await client.post("/v1/investments/providers/dhan/sync", headers=h)
    assert sync.status_code == 503 and sync.json()["code"].startswith("provider_")
    assert (await client.get("/v1/investments/portfolio")).status_code == 401
    paths = [getattr(r, "path", "") for r in app.routes]
    assert not any("order" in p for p in paths if p.startswith("/v1/investments"))
    caps = {c.id: c for c in registry.capabilities.all(domain="investment")}
    assert caps["investment.orders.placement"].status.value == "unavailable"
    assert caps["investment.fundamentals"].status.value == "unavailable"
