"""Google OAuth 2.0 for an installed app: authorization code + PKCE, refresh, revocation.

State machine (persisted in `SecretStore`, sealed): not_configured -> not_connected -> connected ->
expired. A refresh that Google answers with `invalid_grant` means the refresh token was revoked by the
owner, or expired: apps whose consent screen is in "Testing" (unverified) get refresh tokens that
last 7 days. That is stored as the `expired` state and reported honestly; the access path then
raises `GoogleError("expired")` until the owner connects again. `connected_at + 7 days` is exposed as
a hint so the app can warn before it happens.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets as pysecrets
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Literal
from urllib.parse import urlencode

import httpx

from app.communications.google.endpoints import SCOPES, UNVERIFIED_REFRESH_DAYS, GoogleEndpoints
from app.core.clock import Clock
from app.security.secrets import SecretStore

HttpFactory = Callable[[], httpx.AsyncClient]
GoogleErrorKind = Literal[
    "not_configured",
    "not_connected",
    "expired",
    "forbidden",
    "not_found",
    "rate_limited",
    "bad_request",
    "unavailable",
]
PROVIDER = "google"
PENDING = "google_pkce"
PENDING_TTL = timedelta(minutes=10)
_MARGIN = timedelta(seconds=60)
_TIMEOUT = httpx.Timeout(15.0, connect=5.0)


def pkce_pair() -> tuple[str, str]:
    """(verifier, S256 challenge), RFC 7636."""
    verifier = pysecrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return verifier, base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


class GoogleError(Exception):
    def __init__(self, kind: GoogleErrorKind, message: str = "", *, retry_after_s: int | None = None) -> None:
        super().__init__(f"{kind}: {message}" if message else kind)
        self.kind: GoogleErrorKind = kind
        self.message = message
        self.retry_after_s = retry_after_s


@dataclass(frozen=True)
class GoogleState:
    state: Literal["not_configured", "not_connected", "connected", "expired"]
    connected_at: datetime | None = None
    expired_at: datetime | None = None
    refresh_expiry_hint_at: datetime | None = None  # connected_at + 7 days (unverified apps only)


class GoogleOAuth:
    def __init__(
        self,
        *,
        secrets: SecretStore,
        clock: Clock,
        http: HttpFactory,
        client_id: Callable[[], str | None],
        client_secret: Callable[[], str | None],
        redirect_uri: Callable[[], str],
        endpoints: GoogleEndpoints | None = None,
    ) -> None:
        self._secrets = secrets
        self._clock = clock
        self._http = http
        self._client_id = client_id
        self._client_secret = client_secret
        self._redirect_uri = redirect_uri
        self.endpoints = endpoints or GoogleEndpoints()
        self._lock = asyncio.Lock()
        self.state_hint: str = "not_connected"  # last known state for the synchronous capability registry

    @property
    def configured(self) -> bool:
        return bool(self._client_id())

    def _require_client_id(self) -> str:
        client_id = self._client_id()
        if not client_id:
            raise GoogleError("not_configured", "GOOGLE_OAUTH_CLIENT_ID is not set")
        return client_id

    # ------------------------------------------------------------ state

    async def _record(self) -> dict[str, Any] | None:
        raw = await self._secrets.get(PROVIDER, allow_expired=True)
        return None if raw is None else dict(json.loads(raw))

    async def state(self) -> GoogleState:
        if not self.configured:
            self.state_hint = "not_configured"
            return GoogleState("not_configured")
        record = await self._record()
        if record is None:
            self.state_hint = "not_connected"
            return GoogleState("not_connected")
        connected_at = datetime.fromisoformat(record["connected_at"]) if record.get("connected_at") else None
        hint = connected_at + timedelta(days=UNVERIFIED_REFRESH_DAYS) if connected_at else None
        if record.get("state") == "expired":
            self.state_hint = "expired"
            expired_at = datetime.fromisoformat(record["expired_at"]) if record.get("expired_at") else None
            return GoogleState("expired", connected_at, expired_at, hint)
        self.state_hint = "connected"
        return GoogleState("connected", connected_at, None, hint)

    async def disconnect(self) -> bool:
        """Revoke at Google (best effort), then forget the tokens. True when Google confirmed."""
        record = await self._record()
        revoked = False
        token = record and (record.get("refresh_token") or record.get("access_token"))
        if token:
            try:
                async with self._http() as client:
                    response = await client.post(
                        self.endpoints.revoke, data={"token": token}, timeout=_TIMEOUT
                    )
                revoked = response.status_code == 200
            except httpx.HTTPError:
                revoked = False
        await self._secrets.delete(PROVIDER)
        self.state_hint = "not_connected"
        return revoked

    # ------------------------------------------------------------ authorization (code + PKCE)

    async def begin_authorization(self) -> tuple[str, str, datetime]:
        client_id = self._require_client_id()
        verifier, challenge = pkce_pair()
        state = pysecrets.token_urlsafe(32)
        expires = self._clock.now() + PENDING_TTL
        await self._secrets.put(PENDING, verifier, account=state, expires_at=expires)
        query = urlencode(
            {
                "response_type": "code",
                "client_id": client_id,
                "redirect_uri": self._redirect_uri(),
                "scope": " ".join(SCOPES),
                "state": state,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "access_type": "offline",  # a refresh token
                "prompt": "consent",  # so Google returns the refresh token again on re-connect
                "include_granted_scopes": "true",
            }
        )
        return f"{self.endpoints.authorize}?{query}", state, expires

    async def complete_authorization(self, state: str, code: str) -> None:
        client_id = self._require_client_id()
        verifier = await self._secrets.get(PENDING, account=state)
        if verifier is None:
            raise GoogleError("bad_request", "unknown or expired state")
        await self._secrets.delete(PENDING, account=state)  # single use
        form = {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": self._redirect_uri(),
            "client_id": client_id,
            "code_verifier": verifier,
        }
        if secret := self._client_secret():
            form["client_secret"] = secret
        payload = await self._token_request(form)
        if not payload.get("refresh_token"):
            raise GoogleError("bad_request", "Google returned no refresh token; connect again")
        await self._store(payload, previous=None)

    async def _token_request(self, form: dict[str, str]) -> dict[str, Any]:
        try:
            async with self._http() as client:
                response = await client.post(self.endpoints.token, data=form, timeout=_TIMEOUT)
        except httpx.HTTPError as exc:
            raise GoogleError("unavailable", "Google token endpoint unreachable") from exc
        if response.status_code == 400:
            try:
                error = response.json().get("error")
            except ValueError:
                error = None
            if error == "invalid_grant":
                raise GoogleError("expired", "refresh token revoked or expired")
            raise GoogleError("bad_request", str(error or "token request refused"))
        if response.status_code == 429:
            raise GoogleError("rate_limited")
        if response.status_code >= 400:
            raise GoogleError("unavailable", f"token endpoint status {response.status_code}")
        data = response.json()
        if not isinstance(data, dict) or not data.get("access_token"):
            raise GoogleError("unavailable", "token response had no access token")
        return data

    async def _store(self, payload: dict[str, Any], *, previous: dict[str, Any] | None) -> dict[str, Any]:
        now = self._clock.now()
        record = {
            "state": "connected",
            "access_token": payload["access_token"],
            "refresh_token": payload.get("refresh_token") or (previous or {}).get("refresh_token"),
            "expires_at": (now + timedelta(seconds=int(payload.get("expires_in", 3600)))).isoformat(),
            "scope": payload.get("scope", (previous or {}).get("scope", "")),
            # a refresh keeps the refresh token's age; only a new authorization resets it
            "connected_at": (previous or {}).get("connected_at") or now.isoformat(),
        }
        await self._secrets.put(PROVIDER, json.dumps(record))
        self.state_hint = "connected"
        return record

    async def _mark_expired(self, record: dict[str, Any]) -> None:
        expired = {
            "state": "expired",
            "connected_at": record.get("connected_at"),
            "expired_at": self._clock.now().isoformat(),
        }
        await self._secrets.put(PROVIDER, json.dumps(expired))
        self.state_hint = "expired"

    # ------------------------------------------------------------ access token

    async def access_token(self, *, force_refresh: bool = False) -> str:
        async with self._lock:
            if not self.configured:
                raise GoogleError("not_configured", "GOOGLE_OAUTH_CLIENT_ID is not set")
            record = await self._record()
            if record is None:
                self.state_hint = "not_connected"
                raise GoogleError("not_connected", "Google is not connected")
            if record.get("state") == "expired":
                raise GoogleError("expired", "Google sign-in expired")
            expires_at = datetime.fromisoformat(record["expires_at"])
            if not force_refresh and expires_at - _MARGIN > self._clock.now():
                return str(record["access_token"])
            form = {
                "grant_type": "refresh_token",
                "refresh_token": str(record["refresh_token"]),
                "client_id": self._require_client_id(),
            }
            if secret := self._client_secret():
                form["client_secret"] = secret
            try:
                payload = await self._token_request(form)
            except GoogleError as exc:
                if exc.kind == "expired":
                    await self._mark_expired(record)
                raise
            return str((await self._store(payload, previous=record))["access_token"])

    async def mark_expired(self) -> None:
        """A 401 that survived a refresh: the grant is no longer valid."""
        async with self._lock:
            record = await self._record()
            if record is not None and record.get("state") != "expired":
                await self._mark_expired(record)
