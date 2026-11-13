"""Kite and Dhan adapters over httpx.MockTransport (no network): parsing, missing credentials,
expired tokens, provider down, and that no adapter has or uses an order endpoint."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import httpx
import pytest

from app.investment.config import InvestmentConfig
from app.investment.providers.base import ProviderUnavailable
from app.investment.providers.dhan import DhanAdapter
from app.investment.providers.kite import KiteAdapter
from app.investment.schemas import Instrument
from app.plugins import PluginRegistry

KITE_ENV = {"KITE_API_KEY": "kite_key_test", "KITE_API_SECRET": "kite_secret_test"}
DHAN_ENV = {"DHAN_CLIENT_ID": "1000000001"}


class Recorder:
    def __init__(self, handler: Callable[[httpx.Request], httpx.Response]) -> None:
        self.requests: list[httpx.Request] = []
        self._handler = handler

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        response: httpx.Response = self._handler(request)
        return response


def kite(
    registry: PluginRegistry,
    cfg: InvestmentConfig,
    handler: Callable[[httpx.Request], httpx.Response],
    env: dict[str, str] | None = None,
) -> tuple[KiteAdapter, Recorder]:
    rec = Recorder(handler)
    adapter = KiteAdapter(cfg.providers["kite"], registry.service("secrets"), registry.service("clock"),
                          KITE_ENV if env is None else env, httpx.MockTransport(rec))  # fmt: skip
    return adapter, rec


def dhan(
    registry: PluginRegistry, cfg: InvestmentConfig, handler: Callable[[httpx.Request], httpx.Response]
) -> tuple[DhanAdapter, Recorder]:
    rec = Recorder(handler)
    adapter = DhanAdapter(cfg.providers["dhan"], registry.service("secrets"), registry.service("clock"), DHAN_ENV,
                          httpx.MockTransport(rec))  # fmt: skip
    return adapter, rec


def ok(payload: object) -> httpx.Response:
    return httpx.Response(200, text=json.dumps(payload))


async def test_kite_without_credentials_reports_status(
    registry: PluginRegistry, cfg: InvestmentConfig
) -> None:
    adapter, rec = kite(registry, cfg, lambda r: ok({}), env={})
    assert (await adapter.status()).status == "requires_credentials"
    with pytest.raises(ProviderUnavailable) as err:
        await adapter.holdings()
    assert err.value.reason == "requires_credentials" and rec.requests == []
    keyed, _ = kite(registry, cfg, lambda r: ok({}))
    assert (await keyed.status()).status == "requires_credentials"  # key but no session yet


async def test_kite_session_holdings_quotes_candles(registry: PluginRegistry, cfg: InvestmentConfig) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/session/token":
            return ok({"status": "success", "data": {"access_token": "tok_123"}})
        assert request.headers["Authorization"] == "token kite_key_test:tok_123"
        assert request.headers["X-Kite-Version"] == "3"
        if path == "/portfolio/holdings":
            return ok(
                {
                    "status": "success",
                    "data": [
                        {
                            "tradingsymbol": "INFY",
                            "exchange": "NSE",
                            "instrument_token": 408065,
                            "isin": "INE009A01021",
                            "quantity": 10,
                            "t1_quantity": 2,
                            "average_price": 1400.55,
                            "last_price": 1501.1,
                        },
                        {
                            "tradingsymbol": "GOLDBEES",
                            "exchange": "MCX",
                            "quantity": 1,
                            "average_price": 1,
                            "last_price": 1,
                        },
                    ],
                }
            )
        if path == "/quote":
            return ok(
                {
                    "status": "success",
                    "data": {
                        "NSE:INFY": {
                            "last_price": 1499.95,
                            "volume": 12345,
                            "last_trade_time": "2026-11-12 15:29:59",
                        }
                    },
                }
            )
        if path == "/instruments/historical/408065/day":
            return ok(
                {
                    "status": "success",
                    "data": {
                        "candles": [
                            ["2026-11-11T00:00:00+0530", 1480.0, 1510.5, 1475.25, 1500.1, 100000],
                            ["2026-11-12T00:00:00+0530", 1500.1, 1520.0, 1490.0, 1499.95, 90000],
                        ]
                    },
                }
            )
        return httpx.Response(404)  # fmt: skip

    adapter, rec = kite(registry, cfg, handler)
    expires = await adapter.create_session("req_tok")
    body = dict(x.split("=") for x in rec.requests[0].content.decode().split("&"))
    assert body["checksum"] == hashlib.sha256(b"kite_key_testreq_tokkite_secret_test").hexdigest()
    assert (
        await registry.service("secrets").get("kite") == "tok_123"
        and expires > registry.service("clock").now()
    )
    assert (await adapter.status()).status == "working"

    [infy] = await adapter.holdings()  # MCX row ignored
    assert (infy.instrument.symbol, infy.quantity, infy.average_price) == (
        "INFY",
        Decimal(12),
        Decimal("1400.55"),
    )
    assert isinstance(infy.last_price, Decimal) and infy.last_price == Decimal("1501.1")  # never a float
    [quote] = await adapter.quotes([Instrument(symbol="INFY")])
    assert quote.last_price == Decimal("1499.95") and quote.as_of == datetime(
        2026, 11, 12, 9, 59, 59, tzinfo=UTC
    )
    series = await adapter.candles(
        Instrument(symbol="INFY", security_id="408065"), date(2026, 11, 1), date(2026, 11, 12)
    )
    assert [c.day for c in series.candles] == [date(2026, 11, 11), date(2026, 11, 12)]
    assert series.candles[0].low == Decimal("1475.25") and series.source == "kite"
    assert all(r.method in ("GET", "POST") and "order" not in r.url.path for r in rec.requests)


async def test_kite_expired_token_and_provider_down(registry: PluginRegistry, cfg: InvestmentConfig) -> None:
    secrets = registry.service("secrets")
    clock = registry.service("clock")
    await secrets.put("kite", "old_tok", expires_at=clock.now() - timedelta(hours=1))
    adapter, rec = kite(registry, cfg, lambda r: ok({}))
    assert (await adapter.status()).status == "token_expired"
    with pytest.raises(ProviderUnavailable) as err:
        await adapter.holdings()
    assert err.value.reason == "token_expired" and rec.requests == []

    await secrets.put("kite", "live_tok", expires_at=clock.now() + timedelta(hours=1))
    rejected, _ = kite(
        registry, cfg, lambda r: httpx.Response(403, json={"status": "error", "error_type": "TokenException"})
    )
    with pytest.raises(ProviderUnavailable) as err:
        await rejected.holdings()
    assert err.value.reason == "token_expired"

    down, _ = kite(registry, cfg, lambda r: httpx.Response(503))
    with pytest.raises(ProviderUnavailable) as err:
        await down.quotes([Instrument(symbol="INFY")])
    assert err.value.reason == "provider_down"

    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("unreachable", request=request)

    offline, _ = kite(registry, cfg, boom)
    with pytest.raises(ProviderUnavailable) as err:
        await offline.positions()
    assert err.value.reason == "provider_down"
    garbage, _ = kite(registry, cfg, lambda r: httpx.Response(200, text="<html>"))
    with pytest.raises(ProviderUnavailable) as err:
        await garbage.holdings()
    assert err.value.reason == "bad_response"


async def test_dhan_quotes_candles_and_expired(registry: PluginRegistry, cfg: InvestmentConfig) -> None:
    await registry.service("secrets").put("dhan", "dhan_tok")

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["access-token"] == "dhan_tok" and request.headers["client-id"] == "1000000001"
        if request.url.path == "/v2/marketfeed/ohlc":
            assert json.loads(request.content) == {"NSE_EQ": [1333]}
            return ok(
                {
                    "status": "success",
                    "data": {
                        "NSE_EQ": {"1333": {"last_price": 1650.4, "ohlc": {"open": 1640, "close": 1645}}}
                    },
                }
            )
        if request.url.path == "/v2/charts/historical":
            return ok(
                {
                    "open": [1640.0],
                    "high": [1660.5],
                    "low": [1630.0],
                    "close": [1650.4],
                    "volume": [5000],
                    "timestamp": [1762919100],
                }
            )
        if request.url.path == "/v2/holdings":
            return ok(
                [
                    {
                        "exchange": "ALL",
                        "tradingSymbol": "HDFCBANK",
                        "securityId": "1333",
                        "totalQty": 4,
                        "avgCostPrice": 1500.25,
                    }
                ]
            )
        return httpx.Response(404)  # fmt: skip

    adapter, rec = dhan(registry, cfg, handler)
    assert (await adapter.status()).status == "working"
    [quote] = await adapter.quotes([Instrument(symbol="HDFCBANK", security_id="1333")])
    assert quote.last_price == Decimal("1650.4") and quote.source == "dhan"
    series = await adapter.candles(
        Instrument(symbol="HDFCBANK", security_id="1333"), date(2025, 11, 1), date(2025, 11, 30)
    )
    assert series.candles[0].close == Decimal("1650.4") and series.candles[0].day == date(2025, 11, 12)
    [held] = await adapter.holdings()
    assert (held.instrument.exchange, held.quantity, held.last_price) == ("NSE", Decimal(4), None)
    with pytest.raises(ProviderUnavailable):
        await adapter.quotes([Instrument(symbol="HDFCBANK")])  # no security id: refused, not guessed

    expired, _ = dhan(registry, cfg, lambda r: httpx.Response(401, json={"errorCode": "DH-901"}))
    with pytest.raises(ProviderUnavailable) as err:
        await expired.holdings()
    assert err.value.reason == "token_expired"
    assert all("order" not in r.url.path for r in rec.requests)


def test_no_order_endpoint_anywhere_in_the_package() -> None:
    root = Path(__file__).resolve().parents[2] / "app" / "investment"
    for source in root.rglob("*.py"):
        text = source.read_text(encoding="utf-8")
        for needle in ('"/orders', "'/orders", "place_order", "/gtt", "modify_order"):
            assert needle not in text, f"{source.name} mentions {needle}"
    assert not hasattr(KiteAdapter, "place_order") and not hasattr(DhanAdapter, "place_order")
