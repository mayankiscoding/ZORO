"""DhanHQ v2 adapter: read-only holdings, positions, OHLC quotes and daily candles.

Credentials: `DHAN_CLIENT_ID` from the environment; the access token from `SecretStore`
(provider "dhan"), falling back to `DHAN_ACCESS_TOKEN`. Only `POST /marketfeed/ohlc` (exchange
segment -> integer security ids) was verified against https://docs.dhanhq.co/api/v2/ in the
research file; `/holdings`, `/positions` and `/charts/historical` shapes are from the same docs but
unverified here. Data APIs are a paid Dhan subscription. This module has no order method.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import UTC, date, datetime
from typing import Any

import httpx

from app.core.clock import Clock
from app.investment.config import BrokerConfig
from app.investment.providers.base import HTTP_TIMEOUT, ProviderUnavailable, send, to_decimal
from app.investment.schemas import (
    BrokerHolding,
    BrokerPosition,
    Candle,
    Instrument,
    ProviderStatus,
    Quote,
    Series,
)
from app.security.secrets import SecretStore

NAME = "dhan"
_SEGMENT = {"NSE": "NSE_EQ", "BSE": "BSE_EQ"}
_EXPIRED = (401, 403)  # DH-901: client id or access token invalid or expired


class DhanAdapter:
    name = NAME

    def __init__(
        self,
        cfg: BrokerConfig,
        secrets: SecretStore,
        clock: Clock,
        env: Mapping[str, str],
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._cfg = cfg
        self._secrets = secrets
        self._clock = clock
        self._env = env
        self._transport = transport

    @property
    def client_id(self) -> str | None:
        return self._env.get(self._cfg.client_id_env or "DHAN_CLIENT_ID") or None

    async def _stored_token(self, *, allow_expired: bool = False) -> str | None:
        token = await self._secrets.get(NAME, allow_expired=allow_expired)
        return token or self._env.get(self._cfg.token_env or "DHAN_ACCESS_TOKEN") or None

    async def status(self) -> ProviderStatus:
        base = {
            "name": NAME,
            "title": self._cfg.title,
            "docs_url": self._cfg.docs_url,
            "endpoints_verified": False,
        }
        if not self.client_id:
            return ProviderStatus(status="requires_credentials", detail="Set DHAN_CLIENT_ID.", **base)
        if await self._stored_token() is None:
            if await self._secrets.get(NAME, allow_expired=True) is not None:
                return ProviderStatus(
                    status="token_expired", detail="Create a new Dhan access token.", **base
                )
            return ProviderStatus(status="requires_credentials", detail="Add a Dhan access token.", **base)
        return ProviderStatus(status="working", detail="Token present; not contacted.", **base)

    async def _auth(self) -> dict[str, str]:
        client_id = self.client_id
        if not client_id:
            raise ProviderUnavailable(NAME, "requires_credentials", "DHAN_CLIENT_ID")
        token = await self._stored_token()
        if token is None:
            expired = await self._secrets.get(NAME, allow_expired=True) is not None
            raise ProviderUnavailable(NAME, "token_expired" if expired else "requires_credentials")
        return {"access-token": token, "client-id": client_id, "Accept": "application/json"}

    async def _call(self, method: str, path: str, body: Any = None) -> Any:
        headers = await self._auth()
        async with httpx.AsyncClient(
            base_url=self._cfg.api_base_url, headers=headers, timeout=HTTP_TIMEOUT, transport=self._transport
        ) as client:
            request = client.build_request(method, path, json=body)
            return await send(NAME, client, request, expired_statuses=_EXPIRED)

    async def holdings(self) -> list[BrokerHolding]:
        rows = await self._call("GET", "/holdings")
        try:
            return [
                BrokerHolding(
                    instrument=Instrument(
                        symbol=row["tradingSymbol"],
                        exchange="BSE" if row.get("exchange") == "BSE" else "NSE",
                        security_id=str(row.get("securityId") or "") or None,
                    ),
                    quantity=to_decimal(row["totalQty"]),
                    average_price=to_decimal(row["avgCostPrice"]),
                    last_price=to_decimal(row["lastTradedPrice"]) if row.get("lastTradedPrice") else None,
                    price_as_of=self._clock.now() if row.get("lastTradedPrice") else None,
                    isin=row.get("isin") or None,
                )
                for row in rows or []
            ]
        except (KeyError, TypeError, ValueError) as exc:
            raise ProviderUnavailable(NAME, "bad_response", type(exc).__name__) from exc

    async def positions(self) -> list[BrokerPosition]:
        rows = await self._call("GET", "/positions")
        try:
            return [
                BrokerPosition(
                    instrument=Instrument(symbol=row["tradingSymbol"],
                                          exchange="BSE" if row.get("exchangeSegment") == "BSE_EQ" else "NSE"),
                    product=str(row.get("productType", "")),
                    quantity=to_decimal(row["netQty"]),
                    average_price=to_decimal(row.get("costPrice") or row.get("buyAvg") or 0),
                    pnl=to_decimal(row.get("unrealizedProfit") or 0) + to_decimal(row.get("realizedProfit") or 0),
                )
                for row in rows or []
                if row.get("exchangeSegment") in ("NSE_EQ", "BSE_EQ")
            ]  # fmt: skip
        except (KeyError, TypeError, ValueError) as exc:
            raise ProviderUnavailable(NAME, "bad_response", type(exc).__name__) from exc

    async def quotes(self, instruments: list[Instrument]) -> list[Quote]:
        wanted = [i for i in instruments if i.security_id and i.security_id.isdigit()]
        if not wanted:
            raise ProviderUnavailable(NAME, "not_supported", "Dhan quotes need numeric security ids")
        body: dict[str, list[int]] = {}
        for i in wanted:
            body.setdefault(_SEGMENT[i.exchange], []).append(int(i.security_id or 0))
        data = await self._call("POST", "/marketfeed/ohlc", body)
        now = self._clock.now()
        result: list[Quote] = []
        try:
            feed = data.get("data") or {}
            for i in wanted:
                row = (feed.get(_SEGMENT[i.exchange]) or {}).get(str(i.security_id))
                if row and row.get("last_price") is not None:
                    result.append(
                        Quote(instrument=i, last_price=to_decimal(row["last_price"]), as_of=now, source=NAME)
                    )
        except (AttributeError, TypeError, ValueError) as exc:
            raise ProviderUnavailable(NAME, "bad_response", type(exc).__name__) from exc
        return result

    async def candles(self, instrument: Instrument, start: date, end: date) -> Series:
        if not instrument.security_id:
            raise ProviderUnavailable(NAME, "not_supported", "securityId needed for historical data")
        body = {
            "securityId": instrument.security_id, "exchangeSegment": _SEGMENT[instrument.exchange],
            "instrument": "EQUITY", "expiryCode": 0, "fromDate": start.isoformat(), "toDate": end.isoformat(),
        }  # fmt: skip
        data = await self._call("POST", "/charts/historical", body)
        try:
            columns = [data[k] for k in ("timestamp", "open", "high", "low", "close", "volume")]
            candles = [
                Candle(day=datetime.fromtimestamp(int(ts), tz=UTC).date(), open=to_decimal(o), high=to_decimal(h),
                       low=to_decimal(lo), close=to_decimal(c), volume=int(v))
                for ts, o, h, lo, c, v in zip(*columns, strict=True)
            ]  # fmt: skip
        except (KeyError, TypeError, ValueError) as exc:
            raise ProviderUnavailable(NAME, "bad_response", type(exc).__name__) from exc
        if not candles:
            raise ProviderUnavailable(NAME, "no_data")
        return Series(instrument=instrument, candles=candles, source=NAME, fetched_at=self._clock.now())
