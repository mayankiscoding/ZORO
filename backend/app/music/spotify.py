"""Spotify Web API adapter: PKCE authorization, token refresh and the player / search / playlist calls.

Not used (removed for new apps on 2024-11-27): recommendations, audio features, audio analysis,
related artists. "Similar songs" is answered by search, and says so.
Playback endpoints need Spotify Premium; a development-mode app serves only allowlisted users.
Tokens are kept in `SecretStore` (AES-256-GCM); the PKCE verifier is kept there too until used.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets as pysecrets
from collections.abc import Callable
from datetime import datetime, timedelta
from typing import Any, Literal
from urllib.parse import urlencode

import httpx

from app.core.clock import Clock
from app.music.endpoints import SCOPES, SpotifyEndpoints
from app.security.secrets import SecretStore

HttpFactory = Callable[[], httpx.AsyncClient]
ErrorKind = Literal[
    "not_configured",
    "not_connected",
    "reauthorize",
    "premium_required",
    "not_allowlisted",
    "forbidden",
    "no_active_device",
    "not_found",
    "rate_limited",
    "bad_request",
    "unavailable",
]
PROVIDER = "spotify"
PENDING = "spotify_pkce"
PENDING_TTL = timedelta(minutes=10)
_REFRESH_MARGIN = timedelta(seconds=60)
_TIMEOUT = httpx.Timeout(15.0, connect=5.0)
MAX_PLAYLIST_ADD = 100
SEARCH_MAX = 10


class SpotifyError(Exception):
    def __init__(self, kind: ErrorKind, message: str = "", *, retry_after_s: int | None = None) -> None:
        super().__init__(f"{kind}: {message}" if message else kind)
        self.kind: ErrorKind = kind
        self.message = message
        self.retry_after_s = retry_after_s


def pkce_pair() -> tuple[str, str]:
    """(verifier, S256 challenge). The verifier is 43+ URL-safe characters."""
    verifier = pysecrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return verifier, base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


class SpotifyClient:
    def __init__(
        self,
        *,
        secrets: SecretStore,
        clock: Clock,
        http: HttpFactory,
        client_id: Callable[[], str | None],
        redirect_uri: Callable[[], str],
        endpoints: SpotifyEndpoints | None = None,
    ) -> None:
        self._secrets = secrets
        self._clock = clock
        self._http = http
        self._client_id = client_id
        self._redirect_uri = redirect_uri
        self.endpoints = endpoints or SpotifyEndpoints()
        self._lock = asyncio.Lock()
        self.connected_hint = False  # last known state, for the synchronous capability registry
        self.reauth_needed = False

    # ------------------------------------------------------------ configuration and connection

    @property
    def configured(self) -> bool:
        return bool(self._client_id())

    def _require_client_id(self) -> str:
        client_id = self._client_id()
        if not client_id:
            raise SpotifyError("not_configured", "SPOTIFY_CLIENT_ID is not set")
        return client_id

    async def refresh_hint(self) -> bool:
        self.connected_hint = await self._secrets.get(PROVIDER, allow_expired=True) is not None
        return self.connected_hint

    async def is_connected(self) -> bool:
        return await self.refresh_hint()

    async def disconnect(self) -> None:
        await self._secrets.delete(PROVIDER)
        self.connected_hint = False
        self.reauth_needed = False

    # ------------------------------------------------------------ PKCE authorization

    async def begin_authorization(self) -> tuple[str, str, datetime]:
        """(authorize_url, state, expires_at). The verifier never leaves the server."""
        client_id = self._require_client_id()
        verifier, challenge = pkce_pair()
        state = pysecrets.token_urlsafe(32)
        expires = self._clock.now() + PENDING_TTL
        await self._secrets.put(PENDING, verifier, account=state, expires_at=expires)
        query = urlencode(
            {
                "response_type": "code",
                "client_id": client_id,
                "scope": " ".join(SCOPES),
                "redirect_uri": self._redirect_uri(),
                "state": state,
                "code_challenge_method": "S256",
                "code_challenge": challenge,
            }
        )
        return f"{self.endpoints.authorize}?{query}", state, expires

    async def complete_authorization(self, state: str, code: str) -> None:
        client_id = self._require_client_id()
        verifier = await self._secrets.get(PENDING, account=state)
        if verifier is None:
            raise SpotifyError("bad_request", "unknown or expired state")
        await self._secrets.delete(PENDING, account=state)  # single use
        payload = await self._token_request(
            {
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": self._redirect_uri(),
                "client_id": client_id,
                "code_verifier": verifier,
            }
        )
        await self._store(payload, previous_refresh=None)

    async def _token_request(self, form: dict[str, str]) -> dict[str, Any]:
        try:
            async with self._http() as client:
                response = await client.post(self.endpoints.token, data=form, timeout=_TIMEOUT)
        except httpx.HTTPError as exc:
            raise SpotifyError("unavailable", "token endpoint unreachable") from exc
        if response.status_code == 400:
            # invalid_grant: the code or refresh token is no longer valid
            raise SpotifyError("reauthorize", "Spotify rejected the grant")
        if response.status_code == 429:
            raise SpotifyError("rate_limited", retry_after_s=_retry_after(response))
        if response.status_code >= 400:
            raise SpotifyError("unavailable", f"token endpoint status {response.status_code}")
        data = response.json()
        if not isinstance(data, dict) or not data.get("access_token"):
            raise SpotifyError("unavailable", "token response had no access token")
        return data

    async def _store(self, payload: dict[str, Any], *, previous_refresh: str | None) -> dict[str, Any]:
        refresh = payload.get("refresh_token") or previous_refresh
        expires_in = int(payload.get("expires_in", 3600))
        record = {
            "access_token": payload["access_token"],
            "refresh_token": refresh,
            "expires_at": (self._clock.now() + timedelta(seconds=expires_in)).isoformat(),
            "scope": payload.get("scope", ""),
        }
        await self._secrets.put(PROVIDER, json.dumps(record))
        self.connected_hint = True
        self.reauth_needed = False
        return record

    async def _load(self) -> dict[str, Any]:
        raw = await self._secrets.get(PROVIDER, allow_expired=True)
        if raw is None:
            self.connected_hint = False
            raise SpotifyError("not_connected", "Spotify is not connected")
        record: dict[str, Any] = json.loads(raw)
        return record

    async def _access_token(self, *, force_refresh: bool = False) -> str:
        async with self._lock:
            record = await self._load()
            expires_at = datetime.fromisoformat(record["expires_at"])
            if not force_refresh and expires_at - _REFRESH_MARGIN > self._clock.now():
                return str(record["access_token"])
            refresh = record.get("refresh_token")
            if not refresh:
                raise SpotifyError("reauthorize", "no refresh token stored")
            try:
                payload = await self._token_request(
                    {
                        "grant_type": "refresh_token",
                        "refresh_token": refresh,
                        "client_id": self._require_client_id(),
                    }
                )
            except SpotifyError as exc:
                if exc.kind == "reauthorize":
                    self.reauth_needed = True
                raise
            return str((await self._store(payload, previous_refresh=refresh))["access_token"])

    # ------------------------------------------------------------ requests

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
    ) -> httpx.Response:
        token = await self._access_token()
        for attempt in (0, 1):
            try:
                async with self._http() as client:
                    response = await client.request(
                        method,
                        f"{self.endpoints.api}{path}",
                        params=params,
                        json=body,
                        headers={"Authorization": f"Bearer {token}"},
                        timeout=_TIMEOUT,
                    )
            except httpx.HTTPError as exc:
                raise SpotifyError("unavailable", "Spotify is unreachable") from exc
            if response.status_code == 401 and attempt == 0:
                token = await self._access_token(force_refresh=True)
                continue
            break
        try:
            raise_for_response(response)
        except SpotifyError as exc:
            if exc.kind == "reauthorize":
                self.reauth_needed = True
            raise
        return response

    # ------------------------------------------------------------ API methods

    async def search(self, query: str, *, limit: int = 5) -> list[dict[str, Any]]:
        params = {"q": query, "type": "track", "limit": max(1, min(limit, SEARCH_MAX))}
        data = (await self._request("GET", "/search", params=params)).json()
        return [t for t in (data.get("tracks", {}).get("items") or []) if isinstance(t, dict)]

    async def play(
        self,
        *,
        device_id: str | None = None,
        uris: list[str] | None = None,
        context_uri: str | None = None,
    ) -> None:
        body: dict[str, Any] = {}
        if uris:
            body["uris"] = uris
        elif context_uri:
            body["context_uri"] = context_uri
        params = {"device_id": device_id} if device_id else None
        await self._request("PUT", "/me/player/play", params=params, body=body or None)

    async def pause(self, *, device_id: str | None = None) -> None:
        await self._request("PUT", "/me/player/pause", params={"device_id": device_id} if device_id else None)

    async def next(self, *, device_id: str | None = None) -> None:
        await self._request("POST", "/me/player/next", params={"device_id": device_id} if device_id else None)

    async def previous(self, *, device_id: str | None = None) -> None:
        await self._request(
            "POST", "/me/player/previous", params={"device_id": device_id} if device_id else None
        )

    async def queue(self, uri: str, *, device_id: str | None = None) -> None:
        params: dict[str, Any] = {"uri": uri}
        if device_id:
            params["device_id"] = device_id
        await self._request("POST", "/me/player/queue", params=params)

    async def devices(self) -> list[dict[str, Any]]:
        data = (await self._request("GET", "/me/player/devices")).json()
        return [d for d in (data.get("devices") or []) if isinstance(d, dict)]

    async def transfer(self, device_id: str, *, play: bool = True) -> None:
        """Transfer playback. Spotify accepts exactly one device id (more returns 400), so this
        method takes one string and refuses anything that looks like a list."""
        if not isinstance(device_id, str) or not device_id.strip() or "," in device_id:
            raise ValueError("transfer takes exactly one device id")
        await self._request("PUT", "/me/player", body={"device_ids": [device_id], "play": play})

    async def currently_playing(self) -> dict[str, Any] | None:
        response = await self._request("GET", "/me/player/currently-playing")
        if response.status_code == 204 or not response.content:
            return None
        data = response.json()
        return data if isinstance(data, dict) else None

    async def recently_played(
        self, *, limit: int = 20, before_ms: int | None = None, after_ms: int | None = None
    ) -> list[dict[str, Any]]:
        params: dict[str, Any] = {"limit": max(1, min(limit, 50))}
        if before_ms is not None:
            params["before"] = before_ms
        elif after_ms is not None:
            params["after"] = after_ms
        data = (await self._request("GET", "/me/player/recently-played", params=params)).json()
        return [i for i in (data.get("items") or []) if isinstance(i, dict)]

    async def create_playlist(
        self, name: str, *, description: str = "", public: bool = False
    ) -> dict[str, Any]:
        body = {"name": name, "description": description, "public": public}
        data = (await self._request("POST", "/me/playlists", body=body)).json()
        if not isinstance(data, dict) or not data.get("id"):
            raise SpotifyError("unavailable", "playlist response had no id")
        return data

    async def add_tracks(self, playlist_id: str, uris: list[str]) -> int:
        added = 0
        for start in range(0, len(uris), MAX_PLAYLIST_ADD):
            chunk = uris[start : start + MAX_PLAYLIST_ADD]
            await self._request("POST", f"/playlists/{playlist_id}/items", body={"uris": chunk})
            added += len(chunk)
        return added


def _retry_after(response: httpx.Response) -> int | None:
    value = response.headers.get("retry-after", "")
    return int(value) if value.isdigit() else None


def raise_for_response(response: httpx.Response) -> None:
    status = response.status_code
    if status < 400:
        return
    reason = message = ""
    try:
        error = response.json().get("error", {})
        if isinstance(error, dict):
            reason = str(error.get("reason", ""))
            message = str(error.get("message", ""))
    except (ValueError, AttributeError):
        pass
    if status == 401:
        raise SpotifyError("reauthorize", "Spotify rejected the access token")
    if status == 403:
        if reason == "PREMIUM_REQUIRED" or "premium" in message.lower():
            raise SpotifyError("premium_required", message)
        if "not registered" in message.lower() or "allowlist" in message.lower():
            raise SpotifyError("not_allowlisted", message)
        raise SpotifyError("forbidden", message)
    if status == 404:
        raise SpotifyError("no_active_device" if reason == "NO_ACTIVE_DEVICE" else "not_found", message)
    if status == 429:
        raise SpotifyError("rate_limited", retry_after_s=_retry_after(response))
    if status == 400:
        raise SpotifyError("bad_request", message)
    raise SpotifyError("unavailable", f"Spotify status {status}")
