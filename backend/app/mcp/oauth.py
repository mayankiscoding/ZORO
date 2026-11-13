"""Generic OAuth 2.1 client for external MCP servers: discovery (RFC 9728 + RFC 8414), dynamic
client registration (RFC 7591), authorization code with PKCE S256, refresh. Public client
(no secret). Every value that grants access is kept in `SecretStore`, never in config or logs.
"""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any
from urllib.parse import urlencode, urlsplit

import httpx
from pydantic import BaseModel, ConfigDict, ValidationError

from app.core.clock import Clock
from app.security.secrets import SecretStore

from .config import AuthOAuth, ExternalServer, is_safe_url

PENDING_TTL_S = 600
_REFRESH_SKEW_S = 60
_TIMEOUT = httpx.Timeout(10.0)


class OAuthError(Exception):
    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code


@dataclass(frozen=True)
class PkcePair:
    verifier: str
    challenge: str
    method: str = "S256"


def new_pkce() -> PkcePair:
    """RFC 7636: a 64-character verifier from 48 random bytes and its S256 challenge."""
    verifier = secrets.token_urlsafe(48)
    return PkcePair(verifier=verifier, challenge=s256(verifier))


def s256(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


class AuthServerMetadata(BaseModel):
    model_config = ConfigDict(extra="ignore")
    issuer: str = ""
    authorization_endpoint: str
    token_endpoint: str
    registration_endpoint: str | None = None
    code_challenge_methods_supported: list[str] = []


class OAuthTokens(BaseModel):
    model_config = ConfigDict(extra="ignore")
    access_token: str
    token_type: str = "Bearer"  # noqa: S105 - the scheme name, not a credential
    refresh_token: str | None = None
    expires_at: datetime | None = None
    scope: str | None = None


class ClientRecord(BaseModel):
    client_id: str
    authorization_endpoint: str
    token_endpoint: str


@dataclass(frozen=True)
class AuthorizationStart:
    url: str
    state: str


def _provider(server: ExternalServer) -> str:
    return f"mcp.{server.name}"


def _oauth(server: ExternalServer) -> AuthOAuth:
    if not isinstance(server.auth, AuthOAuth):
        raise OAuthError("not_oauth", f"{server.name} does not use OAuth")
    return server.auth


class McpOAuth:
    def __init__(
        self, secrets_store: SecretStore, clock: Clock, *, transport: httpx.AsyncBaseTransport | None = None
    ) -> None:
        self._secrets = secrets_store
        self._clock = clock
        self._transport = transport

    def _http(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transport, timeout=_TIMEOUT, follow_redirects=False)

    # ------------------------------------------------------------ discovery and registration

    async def discover(self, resource_url: str) -> AuthServerMetadata:
        async with self._http() as http:
            issuer = await self._authorization_server(http, resource_url)
            for url in _well_known(issuer, "oauth-authorization-server"):
                data = await _get_json(http, url)
                if data is None:
                    continue
                try:
                    meta = AuthServerMetadata.model_validate(data)
                except ValidationError as exc:
                    raise OAuthError("bad_metadata", "authorization server metadata is invalid") from exc
                for endpoint in (
                    meta.authorization_endpoint,
                    meta.token_endpoint,
                    meta.registration_endpoint,
                ):
                    if endpoint is not None and not is_safe_url(endpoint):
                        raise OAuthError("insecure_endpoint", "OAuth endpoints must use https")
                if "S256" not in meta.code_challenge_methods_supported:
                    raise OAuthError("pkce_unsupported", "the authorization server does not offer PKCE S256")
                return meta
        raise OAuthError("discovery_failed", "no authorization server metadata found")

    async def _authorization_server(self, http: httpx.AsyncClient, resource_url: str) -> str:
        for url in _well_known(resource_url, "oauth-protected-resource"):
            data = await _get_json(http, url)
            servers = data.get("authorization_servers") if isinstance(data, dict) else None
            if isinstance(servers, list) and servers and isinstance(servers[0], str):
                if not is_safe_url(servers[0]):
                    raise OAuthError("insecure_endpoint", "authorization server must use https")
                return servers[0]
        parts = urlsplit(resource_url)
        return f"{parts.scheme}://{parts.netloc}"  # older servers: the resource origin is the issuer

    async def client(self, server: ExternalServer) -> ClientRecord:
        """The registered client for this server, registering one (RFC 7591) the first time."""
        stored = await self._secrets.get(_provider(server), account="client")
        if stored is not None:
            return ClientRecord.model_validate_json(stored)
        auth = _oauth(server)
        assert server.url is not None
        meta = await self.discover(server.url)
        if meta.registration_endpoint is None:
            raise OAuthError(
                "registration_unsupported", "the server does not allow dynamic client registration"
            )
        body = {
            "client_name": auth.client_name,
            "redirect_uris": [auth.redirect_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        }
        if auth.scopes:
            body["scope"] = " ".join(auth.scopes)
        response = await self._post(meta.registration_endpoint, "registration_failed", json=body)
        data = _json_or_error(response, "registration_failed")
        client_id = data.get("client_id")
        if not isinstance(client_id, str) or not client_id:
            raise OAuthError("registration_failed", "no client_id in the registration response")
        record = ClientRecord(
            client_id=client_id,
            authorization_endpoint=meta.authorization_endpoint,
            token_endpoint=meta.token_endpoint,
        )
        await self._secrets.put(_provider(server), record.model_dump_json(), account="client")
        return record

    # ------------------------------------------------------------ authorization code + PKCE

    async def start(self, server: ExternalServer) -> AuthorizationStart:
        auth = _oauth(server)
        record = await self.client(server)
        pkce = new_pkce()
        state = secrets.token_urlsafe(24)
        pending = json.dumps({"verifier": pkce.verifier, "redirect_uri": auth.redirect_uri})
        expires = self._clock.now() + timedelta(seconds=PENDING_TTL_S)
        await self._secrets.put(_provider(server), pending, account=f"pending:{state}", expires_at=expires)
        query = {
            "response_type": "code",
            "client_id": record.client_id,
            "redirect_uri": auth.redirect_uri,
            "code_challenge": pkce.challenge,
            "code_challenge_method": pkce.method,
            "state": state,
            "resource": server.url or "",
        }
        if auth.scopes:
            query["scope"] = " ".join(auth.scopes)
        return AuthorizationStart(url=f"{record.authorization_endpoint}?{urlencode(query)}", state=state)

    async def complete(self, server: ExternalServer, *, code: str, state: str) -> OAuthTokens:
        provider = _provider(server)
        pending = await self._secrets.get(provider, account=f"pending:{state[:128]}")
        if pending is None:
            raise OAuthError("state_invalid", "unknown or expired authorization state")
        await self._secrets.delete(provider, account=f"pending:{state[:128]}")  # one use only
        saved = json.loads(pending)
        record = await self.client(server)
        form = {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": saved["redirect_uri"],
            "client_id": record.client_id,
            "code_verifier": saved["verifier"],
            "resource": server.url or "",
        }
        return await self._token_request(server, record, form, previous=None)

    # ------------------------------------------------------------ tokens

    async def tokens(self, server: ExternalServer) -> OAuthTokens | None:
        stored = await self._secrets.get(_provider(server), account="tokens")
        return OAuthTokens.model_validate_json(stored) if stored is not None else None

    async def access_token(self, server: ExternalServer) -> str | None:
        """A usable access token, refreshed when it is about to expire; None when the owner must
        authorize (again)."""
        tokens = await self.tokens(server)
        if tokens is None:
            return None
        if (
            tokens.expires_at is None
            or tokens.expires_at - timedelta(seconds=_REFRESH_SKEW_S) > self._clock.now()
        ):
            return tokens.access_token
        if tokens.refresh_token is None:
            return None
        try:
            return (await self.refresh(server, tokens)).access_token
        except OAuthError as exc:
            if exc.code == "token_rejected":  # the grant is gone: the owner must authorize again
                await self._secrets.delete(_provider(server), account="tokens")
            return None

    async def refresh(self, server: ExternalServer, tokens: OAuthTokens) -> OAuthTokens:
        if tokens.refresh_token is None:
            raise OAuthError("no_refresh_token")
        record = await self.client(server)
        form = {
            "grant_type": "refresh_token",
            "refresh_token": tokens.refresh_token,
            "client_id": record.client_id,
            "resource": server.url or "",
        }
        return await self._token_request(server, record, form, previous=tokens)

    async def _post(self, url: str, code: str, **kwargs: Any) -> httpx.Response:
        try:
            async with self._http() as http:
                return await http.post(url, **kwargs)
        except httpx.HTTPError as exc:
            raise OAuthError(code, type(exc).__name__) from exc

    async def forget(self, server: ExternalServer) -> None:
        await self._secrets.delete(_provider(server))

    async def _token_request(
        self,
        server: ExternalServer,
        record: ClientRecord,
        form: dict[str, str],
        *,
        previous: OAuthTokens | None,
    ) -> OAuthTokens:
        response = await self._post(
            record.token_endpoint, "token_request_failed", data=form, headers={"Accept": "application/json"}
        )
        if 400 <= response.status_code < 500:
            raise OAuthError("token_rejected", f"HTTP {response.status_code}")
        data = _json_or_error(response, "token_request_failed")
        access = data.get("access_token")
        if not isinstance(access, str) or not access:
            raise OAuthError("token_request_failed", "no access_token in the response")
        expires_in = data.get("expires_in")
        refresh = data.get("refresh_token")
        tokens = OAuthTokens(
            access_token=access,
            token_type=str(data.get("token_type") or "Bearer"),
            refresh_token=refresh
            if isinstance(refresh, str)
            else (previous.refresh_token if previous else None),
            expires_at=self._clock.now() + timedelta(seconds=int(expires_in))
            if isinstance(expires_in, int | float) and expires_in > 0
            else None,
            scope=data.get("scope") if isinstance(data.get("scope"), str) else None,
        )
        await self._secrets.put(_provider(server), tokens.model_dump_json(), account="tokens")
        return tokens


def _well_known(url: str, name: str) -> list[str]:
    """RFC 8414 / 9728: the path-specific location first, then the root."""
    parts = urlsplit(url)
    base = f"{parts.scheme}://{parts.netloc}/.well-known/{name}"
    path = parts.path.rstrip("/")
    return [base + path, base] if path else [base]


async def _get_json(http: httpx.AsyncClient, url: str) -> dict[str, Any] | None:
    try:
        response = await http.get(url, headers={"Accept": "application/json"})
    except httpx.HTTPError:
        return None
    if response.status_code != 200:
        return None
    try:
        data = response.json()
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def _json_or_error(response: httpx.Response, code: str) -> dict[str, Any]:
    if response.status_code >= 400:
        raise OAuthError(code, f"HTTP {response.status_code}")
    try:
        data = response.json()
    except ValueError as exc:
        raise OAuthError(code, "response is not JSON") from exc
    if not isinstance(data, dict):
        raise OAuthError(code, "response is not a JSON object")
    return data
