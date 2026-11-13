"""Zerodha Kite Connect v3 adapter: read-only holdings, positions, quotes and daily candles.

Credentials: `KITE_API_KEY` / `KITE_API_SECRET` from the environment; the daily access token is
kept in `SecretStore` (provider "kite") after the owner's Kite login. Endpoint paths and response
shapes follow https://kite.trade/docs/connect/v3/ but were NOT re-fetched for this build (the
research file verified only the auth model), so `endpoints_verified` is False. Token expiry at
06:00 IST the next morning is likewise unverified. This module has no order method.
"""

from __future__ import annotations

import hashlib
from collections.abc import Mapping
from datetime import UTC, date, datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

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

NAME = "kite"
IST = ZoneInfo("Asia/Kolkata")
_EXPIRED = (401, 403)  # Kite answers 403 with error_type TokenException


class KiteAdapter:
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

    # ------------------------------------------------------------ credentials

    @property
    def api_key(self) -> str | None:
        return self._env.get(self._cfg.key_env or "KITE_API_KEY") or None

    async def status(self) -> ProviderStatus:
        base = {
            "name": NAME,
            "title": self._cfg.title,
            "docs_url": self._cfg.docs_url,
            "endpoints_verified": False,
        }
        if not self.api_key:
            return ProviderStatus(
                status="requires_credentials", detail="Set KITE_API_KEY and KITE_API_SECRET.", **base
            )
        if await self._secrets.get(NAME) is None:
            if await self._secrets.get(NAME, allow_expired=True) is not None:
                return ProviderStatus(status="token_expired", detail="Log in to Kite again (daily).", **base)
            return ProviderStatus(
                status="requires_credentials", detail="Log in to Kite to create a session.", **base
            )
        return ProviderStatus(status="working", detail="Session token present; not contacted.", **base)

    async def _token(self) -> tuple[str, str]:
        key = self.api_key
        if not key:
            raise ProviderUnavailable(NAME, "requires_credentials", "KITE_API_KEY")
        token = await self._secrets.get(NAME)
        if token is None:
            expired = await self._secrets.get(NAME, allow_expired=True) is not None
            raise ProviderUnavailable(NAME, "token_expired" if expired else "requires_credentials")
        return key, token

    def next_expiry(self) -> datetime:
        local = self._clock.now().astimezone(IST)
        expiry = datetime.combine(local.date(), time(6, 0), tzinfo=IST)
        if local >= expiry:
            expiry += timedelta(days=1)
        return expiry.astimezone(UTC)

    async def create_session(self, request_token: str) -> datetime:
        """Exchange the login redirect's `request_token` for an access token (stored, never returned)."""
        key = self.api_key
        secret = self._env.get(self._cfg.secret_env or "KITE_API_SECRET")
        if not key or not secret:
            raise ProviderUnavailable(NAME, "requires_credentials", "KITE_API_KEY and KITE_API_SECRET")
        checksum = hashlib.sha256((key + request_token + secret).encode()).hexdigest()
        async with self._client() as client:
            request = client.build_request(
                "POST", "/session/token",
                data={"api_key": key, "request_token": request_token, "checksum": checksum},
            )  # fmt: skip
            body = await send(NAME, client, request, expired_statuses=_EXPIRED)
        token = (body.get("data") or {}).get("access_token") if isinstance(body, dict) else None
        if not isinstance(token, str) or not token:
            raise ProviderUnavailable(NAME, "bad_response", "no access_token")
        expires = self.next_expiry()
        await self._secrets.put(NAME, token, expires_at=expires)
        return expires

    def _client(self, auth: tuple[str, str] | None = None) -> httpx.AsyncClient:
        headers = {"X-Kite-Version": "3"}
        if auth is not None:
            headers["Authorization"] = f"token {auth[0]}:{auth[1]}"
        return httpx.AsyncClient(
            base_url=self._cfg.api_base_url, headers=headers, timeout=HTTP_TIMEOUT, transport=self._transport
        )

    async def _get(self, path: str, params: Any = None) -> Any:
        auth = await self._token()
        async with self._client(auth) as client:
            body = await send(
                NAME, client, client.build_request("GET", path, params=params), expired_statuses=_EXPIRED
            )
        if not isinstance(body, dict) or body.get("status") != "success":
            raise ProviderUnavailable(NAME, "bad_response", "status is not success")
        return body.get("data")

    # ------------------------------------------------------------ data

    async def holdings(self) -> list[BrokerHolding]:
        data = await self._get("/portfolio/holdings")
        now = self._clock.now()
        try:
            return [
                BrokerHolding(
                    instrument=Instrument(symbol=row["tradingsymbol"], exchange=row["exchange"],
                                          security_id=str(row.get("instrument_token") or "") or None),
                    quantity=to_decimal(row["quantity"]) + to_decimal(row.get("t1_quantity", 0)),
                    average_price=to_decimal(row["average_price"]),
                    last_price=to_decimal(row["last_price"]) if row.get("last_price") else None,
                    price_as_of=now if row.get("last_price") else None,
                    isin=row.get("isin") or None,
                )
                for row in data or []
                if row.get("exchange") in ("NSE", "BSE")
            ]  # fmt: skip
        except (KeyError, TypeError, ValueError) as exc:
            raise ProviderUnavailable(NAME, "bad_response", type(exc).__name__) from exc

    async def positions(self) -> list[BrokerPosition]:
        data = await self._get("/portfolio/positions")
        try:
            return [
                BrokerPosition(
                    instrument=Instrument(symbol=row["tradingsymbol"], exchange=row["exchange"]),
                    product=str(row.get("product", "")),
                    quantity=to_decimal(row["quantity"]),
                    average_price=to_decimal(row["average_price"]),
                    last_price=to_decimal(row["last_price"]) if row.get("last_price") is not None else None,
                    pnl=to_decimal(row["pnl"]) if row.get("pnl") is not None else None,
                )
                for row in (data or {}).get("net", [])
                if row.get("exchange") in ("NSE", "BSE")
            ]
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            raise ProviderUnavailable(NAME, "bad_response", type(exc).__name__) from exc

    async def quotes(self, instruments: list[Instrument]) -> list[Quote]:
        if not instruments:
            return []
        data = await self._get("/quote", params=[("i", i.key) for i in instruments])
        result: list[Quote] = []
        try:
            for instrument in instruments:
                row = (data or {}).get(instrument.key)
                if not row:
                    continue
                stamp = row.get("last_trade_time") or row.get("timestamp")
                as_of = (
                    datetime.fromisoformat(str(stamp)).replace(tzinfo=IST).astimezone(UTC)
                    if stamp else self._clock.now()
                )  # fmt: skip
                result.append(
                    Quote(instrument=instrument, last_price=to_decimal(row["last_price"]), as_of=as_of,
                          source=NAME, volume=row.get("volume"))
                )  # fmt: skip
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            raise ProviderUnavailable(NAME, "bad_response", type(exc).__name__) from exc
        return result

    async def candles(self, instrument: Instrument, start: date, end: date) -> Series:
        if not instrument.security_id:
            raise ProviderUnavailable(NAME, "not_supported", "instrument_token needed for historical data")
        params = {"from": f"{start.isoformat()} 00:00:00", "to": f"{end.isoformat()} 23:59:59"}
        data = await self._get(f"/instruments/historical/{instrument.security_id}/day", params=params)
        try:
            candles = [
                Candle(day=datetime.fromisoformat(str(r[0])).date(), open=to_decimal(r[1]), high=to_decimal(r[2]),
                       low=to_decimal(r[3]), close=to_decimal(r[4]), volume=int(r[5]))
                for r in (data or {}).get("candles", [])
            ]  # fmt: skip
        except (KeyError, TypeError, ValueError, IndexError, AttributeError) as exc:
            raise ProviderUnavailable(NAME, "bad_response", type(exc).__name__) from exc
        if not candles:
            raise ProviderUnavailable(NAME, "no_data")
        return Series(instrument=instrument, candles=candles, source=NAME, fetched_at=self._clock.now())
