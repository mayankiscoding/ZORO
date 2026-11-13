"""OAuth 2.1 + PKCE + dynamic client registration helper, against httpx.MockTransport (no network)."""

from __future__ import annotations

import base64
import hashlib
import json
import re
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from app.core.clock import FixedClock
from app.mcp.config import ExternalServer
from app.mcp.oauth import McpOAuth, OAuthError, new_pkce, s256
from app.plugins import PluginRegistry
from app.security.secrets import SecretStore

SERVER = ExternalServer.model_validate(
    {
        "name": "im",
        "url": "https://mcp.example.test/im",
        "auth": {"kind": "oauth", "redirect_uri": "http://localhost:8000/cb", "scopes": ["mcp"]},
        "enabled": True,
    }
)


class FakeAuthServer:
    """Protected-resource and authorization-server metadata, registration and token endpoints."""

    def __init__(self) -> None:
        self.token_requests: list[dict[str, str]] = []
        self.registrations: list[dict[str, Any]] = []
        self.issued = 0
        self.reject_refresh = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/.well-known/oauth-protected-resource/im":
            return httpx.Response(200, json={"resource": "https://mcp.example.test/im",
                                             "authorization_servers": ["https://auth.example.test"]})  # fmt: skip
        if path == "/.well-known/oauth-authorization-server":
            return httpx.Response(200, json={
                "issuer": "https://auth.example.test",
                "authorization_endpoint": "https://auth.example.test/authorize",
                "token_endpoint": "https://auth.example.test/token",
                "registration_endpoint": "https://auth.example.test/register",
                "code_challenge_methods_supported": ["S256"],
            })  # fmt: skip
        if path == "/register":
            body = json.loads(request.content)
            self.registrations.append(body)
            return httpx.Response(201, json={"client_id": "client-123", **body})
        if path == "/token":
            form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
            self.token_requests.append(form)
            if form["grant_type"] == "refresh_token" and self.reject_refresh:
                return httpx.Response(400, json={"error": "invalid_grant"})
            self.issued += 1
            return httpx.Response(200, json={"access_token": f"at-{self.issued}", "token_type": "Bearer",
                                             "expires_in": 3600, "refresh_token": f"rt-{self.issued}"})  # fmt: skip
        return httpx.Response(404)


@pytest.fixture
def fixed() -> FixedClock:
    return FixedClock(datetime(2026, 11, 13, 9, 0, tzinfo=UTC))


@pytest.fixture
def oauth_parts(registry: PluginRegistry, fixed: FixedClock) -> tuple[McpOAuth, FakeAuthServer, SecretStore]:
    fake = FakeAuthServer()
    store = SecretStore(registry.service("session_factory"), registry.service("cipher"), fixed)
    return McpOAuth(store, fixed, transport=httpx.MockTransport(fake)), fake, store


def test_pkce_values() -> None:
    pair = new_pkce()
    assert 43 <= len(pair.verifier) <= 128 and re.fullmatch(r"[A-Za-z0-9\-._~]+", pair.verifier)
    expected = base64.urlsafe_b64encode(hashlib.sha256(pair.verifier.encode()).digest()).rstrip(b"=").decode()
    assert pair.challenge == expected and pair.method == "S256" and "=" not in pair.challenge
    assert s256("abc") == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"  # SHA-256("abc"), base64url
    assert new_pkce().verifier != pair.verifier


async def test_authorization_code_flow_and_refresh(
    oauth_parts: tuple[McpOAuth, FakeAuthServer, SecretStore], fixed: FixedClock
) -> None:
    oauth, fake, store = oauth_parts
    started = await oauth.start(SERVER)
    query = {k: v[0] for k, v in parse_qs(urlsplit(started.url).query).items()}
    assert started.url.startswith("https://auth.example.test/authorize?")
    assert query["client_id"] == "client-123" and query["code_challenge_method"] == "S256"
    assert query["state"] == started.state and query["resource"] == SERVER.url and query["scope"] == "mcp"
    assert fake.registrations[0]["token_endpoint_auth_method"] == "none"
    assert fake.registrations[0]["redirect_uris"] == ["http://localhost:8000/cb"]

    tokens = await oauth.complete(SERVER, code="the-code", state=started.state)
    sent = fake.token_requests[-1]
    assert sent["grant_type"] == "authorization_code" and sent["code"] == "the-code"
    assert s256(sent["code_verifier"]) == query["code_challenge"]  # the verifier matches the challenge
    assert tokens.access_token == "at-1" and await oauth.access_token(SERVER) == "at-1"
    assert "at-1" in (await store.get("mcp.im", account="tokens") or "")  # kept through SecretStore

    with pytest.raises(OAuthError) as replay:  # a state is single use
        await oauth.complete(SERVER, code="the-code", state=started.state)
    assert replay.value.code == "state_invalid"

    fixed.advance(3600)  # expired: refreshed transparently
    assert await oauth.access_token(SERVER) == "at-2"
    assert fake.token_requests[-1] == {
        "grant_type": "refresh_token", "refresh_token": "rt-1", "client_id": "client-123", "resource": SERVER.url,
    }  # fmt: skip
    assert len(fake.registrations) == 1  # the registered client is reused

    fixed.advance(3600)
    fake.reject_refresh = True  # the grant was revoked: tokens dropped, the owner must sign in again
    assert await oauth.access_token(SERVER) is None
    assert await oauth.tokens(SERVER) is None


async def test_expired_state_and_insecure_metadata_refused(
    oauth_parts: tuple[McpOAuth, FakeAuthServer, SecretStore], fixed: FixedClock, registry: PluginRegistry
) -> None:
    oauth, _fake, _store = oauth_parts
    started = await oauth.start(SERVER)
    fixed.advance(601)
    with pytest.raises(OAuthError) as expired:
        await oauth.complete(SERVER, code="c", state=started.state)
    assert expired.value.code == "state_invalid"

    def insecure(request: httpx.Request) -> httpx.Response:
        if request.url.path.startswith("/.well-known/oauth-authorization-server"):
            return httpx.Response(200, json={"authorization_endpoint": "http://evil.test/a",
                                             "token_endpoint": "https://a.test/t",
                                             "code_challenge_methods_supported": ["S256"]})  # fmt: skip
        return httpx.Response(404)

    bad = McpOAuth(registry.service("secrets"), fixed, transport=httpx.MockTransport(insecure))
    with pytest.raises(OAuthError) as caught:
        await bad.discover("https://mcp.example.test/im")
    assert caught.value.code == "insecure_endpoint"
