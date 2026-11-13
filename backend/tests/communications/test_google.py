"""Google OAuth (code + PKCE, refresh, expiry, revocation) and the Gmail adapter."""

from __future__ import annotations

import base64
import hashlib
import json
from collections.abc import Callable
from datetime import timedelta
from email.header import decode_header, make_header
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from sqlalchemy import text

from app.communications.compose import wa_link
from app.communications.google.gmail import GmailClient, build_raw, html_to_text, valid_address
from app.communications.google.oauth import GoogleError, GoogleOAuth
from app.communications.plugin import communication_capabilities
from app.core.clock import FixedClock
from app.plugins import PluginRegistry
from tests.communications.conftest import GMAIL, REVOKE, TOKEN, b64, decode_raw, gmail_message, seed_tokens
from tests.conftest import PairedDevice

Route = Callable[[httpx.Request], httpx.Response]
AddRoute = Callable[[str, str, Route], None]


def challenge_of(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


# ---------------------------------------------------------------- OAuth


async def test_connect_needs_client_id(client: httpx.AsyncClient, paired_device: PairedDevice) -> None:
    r = await client.post("/v1/communications/gmail/connect", headers=paired_device.headers)
    assert r.status_code == 503 and r.json()["code"] == "requires_credentials"
    status = (await client.get("/v1/communications/gmail/status", headers=paired_device.headers)).json()
    assert status["state"] == "not_configured"


async def test_authorization_code_pkce_flow(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    route: AddRoute,
    seen: list[httpx.Request],
    clock: FixedClock,
) -> None:
    env["GOOGLE_OAUTH_CLIENT_ID"] = "gclient"
    env["GOOGLE_OAUTH_CLIENT_SECRET"] = "gsecret"
    r = await client.post("/v1/communications/gmail/connect", headers=paired_device.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    url = urlparse(body["authorize_url"])
    q = {k: v[0] for k, v in parse_qs(url.query).items()}
    assert url.netloc == "accounts.google.com"
    assert q["response_type"] == "code" and q["code_challenge_method"] == "S256"
    assert q["access_type"] == "offline" and q["prompt"] == "consent"
    assert q["redirect_uri"] == "http://127.0.0.1:8000/v1/communications/gmail/callback"
    scopes = q["scope"].split()
    assert "https://www.googleapis.com/auth/gmail.compose" in scopes and len(scopes) == 2
    assert "gsecret" not in body["authorize_url"]
    verifier = await registry.service("secrets").get("google_pkce", account=body["state"])
    assert verifier and q["code_challenge"] == challenge_of(verifier)

    route(
        "POST",
        TOKEN,
        lambda req: httpx.Response(
            200, json={"access_token": "AT-new", "refresh_token": "RT-new", "expires_in": 3599, "scope": "s"}
        ),
    )
    cb = await client.get(
        "/v1/communications/gmail/callback", params={"code": "c0de", "state": body["state"]}
    )
    assert cb.status_code == 200 and "Gmail is connected" in cb.text
    form = parse_qs(seen[-1].content.decode())
    assert form["grant_type"] == ["authorization_code"] and form["code_verifier"] == [verifier]
    assert (
        form["client_id"] == ["gclient"] and form["client_secret"] == ["gsecret"] and form["code"] == ["c0de"]
    )

    again = await client.get(
        "/v1/communications/gmail/callback", params={"code": "c0de", "state": body["state"]}
    )
    assert again.status_code == 400 and again.json()["code"] == "callback_invalid"  # state is single use

    async with registry.service("session_factory")() as s:
        sealed = (await s.execute(text("select ciphertext from integration_credentials"))).scalars().all()
    assert sealed and all("AT-new" not in c and "RT-new" not in c for c in sealed)

    st = (await client.get("/v1/communications/gmail/status", headers=paired_device.headers)).json()
    assert st["state"] == "connected"
    # unverified (Testing) apps lose the refresh token after 7 days: the app can warn in advance
    assert st["refresh_expiry_hint_at"].startswith(
        (clock.now() + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M")
    )


async def test_callback_without_refresh_token_is_refused(
    client: httpx.AsyncClient, paired_device: PairedDevice, env: dict[str, str], route: AddRoute
) -> None:
    env["GOOGLE_OAUTH_CLIENT_ID"] = "gclient"
    state = (await client.post("/v1/communications/gmail/connect", headers=paired_device.headers)).json()[
        "state"
    ]
    route("POST", TOKEN, lambda req: httpx.Response(200, json={"access_token": "AT", "expires_in": 3600}))
    r = await client.get("/v1/communications/gmail/callback", params={"code": "c", "state": state})
    assert r.status_code == 400 and r.json()["code"] == "callback_invalid"
    assert (await client.get("/v1/communications/gmail/callback", params={"error": "access_denied"})).json()[
        "code"
    ] == "google_denied"
    assert (
        await client.get("/v1/communications/gmail/callback", params={"code": "c", "state": "forged"})
    ).status_code == 400


async def test_refresh_then_expired_refresh_token(
    connected: None,
    registry: PluginRegistry,
    clock: FixedClock,
    route: AddRoute,
    seen: list[httpx.Request],
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
) -> None:
    oauth: GoogleOAuth = registry.service("google_oauth")
    clock.advance(delta=timedelta(minutes=30))  # still valid: no refresh
    assert await oauth.access_token() == "AT-1" and seen == []
    clock.advance(delta=timedelta(minutes=40))
    route("POST", TOKEN, lambda req: httpx.Response(200, json={"access_token": "AT-2", "expires_in": 3600}))
    assert await oauth.access_token() == "AT-2"
    form = parse_qs(seen[-1].content.decode())
    assert form["grant_type"] == ["refresh_token"] and form["refresh_token"] == ["RT-1"]
    state = await oauth.state()
    assert state.state == "connected" and state.connected_at is not None
    assert state.connected_at < clock.now() - timedelta(hours=1)  # a refresh does not reset the token's age

    # 7 days later Google refuses the refresh token (unverified app, or the owner revoked access)
    clock.advance(delta=timedelta(days=7))
    route("POST", TOKEN, lambda req: httpx.Response(400, json={"error": "invalid_grant"}))
    with pytest.raises(GoogleError) as err:
        await oauth.access_token()
    assert err.value.kind == "expired"
    expired = await oauth.state()
    assert expired.state == "expired" and expired.expired_at is not None
    n_calls = len(seen)
    with pytest.raises(GoogleError):  # no further calls to Google until the owner reconnects
        await oauth.access_token()
    assert len(seen) == n_calls
    caps = {c.id: c for c in communication_capabilities(oauth)}
    assert caps["communications.gmail"].status.value == "manual_user_step"
    assert "expired" in caps["communications.gmail"].note


async def test_disconnect_revokes_at_google(
    connected: None, registry: PluginRegistry, route: AddRoute, seen: list[httpx.Request]
) -> None:
    route("POST", REVOKE, lambda req: httpx.Response(200))
    oauth: GoogleOAuth = registry.service("google_oauth")
    assert await oauth.disconnect() is True
    assert parse_qs(seen[-1].content.decode()) == {"token": ["RT-1"]}
    assert (await oauth.state()).state == "not_connected"


async def test_disconnect_survives_google_being_down(
    connected: None, registry: PluginRegistry, route: AddRoute
) -> None:
    route("POST", REVOKE, lambda req: httpx.Response(400, json={"error": "invalid_token"}))
    oauth: GoogleOAuth = registry.service("google_oauth")
    assert await oauth.disconnect() is False
    assert (await oauth.state()).state == "not_connected"  # tokens are gone locally regardless


# ---------------------------------------------------------------- Gmail adapter


async def test_search_and_get_for_receipts(
    connected: None, registry: PluginRegistry, route: AddRoute, seen: list[httpx.Request]
) -> None:
    gmail: GmailClient = registry.service("gmail")
    route(
        "GET",
        f"{GMAIL}/messages",
        lambda r: httpx.Response(
            200, json={"messages": [{"id": "m1", "threadId": "t1"}, {"id": "m2", "threadId": "t2"}]}
        ),
    )
    route(
        "GET",
        f"{GMAIL}/messages/m1",
        lambda r: httpx.Response(
            200,
            json=gmail_message("m1", "t1", "Your receipt", "Shop <shop@example.com>", "", headers_only=True),
        ),
    )
    route(
        "GET",
        f"{GMAIL}/messages/m2",
        lambda r: httpx.Response(
            200, json=gmail_message("m2", "t2", "Invoice", "Bill <bill@example.com>", "", headers_only=True)
        ),
    )
    found = await gmail.search("from:shop@example.com receipt", 2)
    assert [m.id for m in found] == ["m1", "m2"] and found[0].subject == "Your receipt"
    assert found[0].sender == "Shop <shop@example.com>" and found[0].date is not None
    first = seen[0]
    assert first.headers["authorization"] == "Bearer AT-1"
    assert first.url.params["q"] == "from:shop@example.com receipt" and first.url.params["maxResults"] == "2"
    meta = next(r for r in seen if r.url.path.endswith("/messages/m1"))
    assert meta.url.params["format"] == "metadata"

    pdf = {
        "mimeType": "application/pdf",
        "filename": "receipt.pdf",
        "body": {"attachmentId": "att1", "size": 1234},
    }
    html_only = gmail_message("m3", "t3", "Receipt", "Shop <shop@example.com>", "ignored", parts=[pdf])
    route("GET", f"{GMAIL}/messages/m3", lambda r: httpx.Response(200, json=html_only))
    full = await gmail.get("m3")
    assert full.body_text == "ignored" and full.attachments[0].filename == "receipt.pdf"
    assert seen[-1].url.params["format"] == "full"


async def test_html_only_message_is_converted_to_text(
    connected: None, registry: PluginRegistry, route: AddRoute
) -> None:
    raw = gmail_message("m9", "t9", "Promo", "a@b.com", "x")
    raw["payload"]["parts"] = [
        {"mimeType": "text/html", "body": {"data": b64("<p>Total: <b>Rs 499</b></p><script>x()</script>")}}
    ]
    route("GET", f"{GMAIL}/messages/m9", lambda r: httpx.Response(200, json=raw))
    message = await registry.service("gmail").get("m9")
    assert message.body_text == "Total: Rs 499" and "<b>" in message.body_html
    assert html_to_text("<div>a</div><div>b</div>") == "a\nb"


async def test_gmail_errors_and_401_retry(
    connected: None, registry: PluginRegistry, route: AddRoute, clock: FixedClock
) -> None:
    gmail: GmailClient = registry.service("gmail")
    state = {"n": 0}

    def flaky(req: httpx.Request) -> httpx.Response:
        state["n"] += 1
        if req.headers["authorization"] == "Bearer AT-1":
            return httpx.Response(401, json={})
        return httpx.Response(200, json={"messages": []})

    route("GET", f"{GMAIL}/messages", flaky)
    route("POST", TOKEN, lambda r: httpx.Response(200, json={"access_token": "AT-9", "expires_in": 3600}))
    assert await gmail.search("x") == [] and state["n"] == 2

    cases = [
        (
            httpx.Response(403, json={"error": {"errors": [{"reason": "insufficientPermissions"}]}}),
            "forbidden",
        ),
        (httpx.Response(403, json={"error": {"errors": [{"reason": "rateLimitExceeded"}]}}), "rate_limited"),
        (httpx.Response(429, headers={"Retry-After": "9"}, json={}), "rate_limited"),
        (httpx.Response(404, json={}), "not_found"),
        (httpx.Response(500, json={}), "unavailable"),
    ]
    for response, kind in cases:
        route("GET", f"{GMAIL}/messages/zz", lambda r, resp=response: resp)  # type: ignore[misc]
        with pytest.raises(GoogleError) as err:
            await gmail.get("zz")
        assert err.value.kind == kind


async def test_persistent_401_marks_the_grant_expired(
    connected: None, registry: PluginRegistry, route: AddRoute
) -> None:
    route("GET", f"{GMAIL}/messages", lambda r: httpx.Response(401, json={}))
    route("POST", TOKEN, lambda r: httpx.Response(200, json={"access_token": "AT-9", "expires_in": 3600}))
    with pytest.raises(GoogleError) as err:
        await registry.service("gmail").search("x")
    assert err.value.kind == "expired"
    assert (await registry.service("google_oauth").state()).state == "expired"


async def test_gmail_when_not_connected(registry: PluginRegistry, env: dict[str, str]) -> None:
    with pytest.raises(GoogleError) as err:
        await registry.service("gmail").search("x")
    assert err.value.kind == "not_configured"
    env["GOOGLE_OAUTH_CLIENT_ID"] = "gclient"
    with pytest.raises(GoogleError) as err2:
        await registry.service("gmail").search("x")
    assert err2.value.kind == "not_connected"


async def test_draft_and_send_bodies_are_exact(
    connected: None, registry: PluginRegistry, route: AddRoute, seen: list[httpx.Request]
) -> None:
    gmail: GmailClient = registry.service("gmail")
    route(
        "POST",
        f"{GMAIL}/drafts",
        lambda r: httpx.Response(200, json={"id": "d1", "message": {"id": "m1", "threadId": "t1"}}),
    )
    route(
        "POST",
        f"{GMAIL}/messages/send",
        lambda r: httpx.Response(200, json={"id": "sent1", "threadId": "t1"}),
    )
    body = "नमस्ते अनीता,\n\nरिपोर्ट तैयार है।\nकल मिलते हैं।"
    ref = await gmail.create_draft(to="anita@example.com", subject="रिपोर्ट", body=body, thread_id="t1")
    assert ref.draft_id == "d1"
    sent_body = json.loads(seen[-1].content)
    assert sent_body["message"]["threadId"] == "t1"
    headers, decoded = decode_raw(sent_body["message"]["raw"])
    assert decoded == body and headers["To"] == "anita@example.com"
    assert str(make_header(decode_header(headers["Subject"]))) == "रिपोर्ट"
    sent = await gmail.send(to="anita@example.com", subject="Hi", body="Exact words.")
    assert sent.message_id == "sent1"
    assert decode_raw(json.loads(seen[-1].content)["raw"])[1].strip() == "Exact words."


def test_header_injection_and_bad_addresses_are_refused() -> None:
    for bad in ("a@b.com\r\nBcc: x@y.com", "a@b.com, c@d.com", "no-at-sign", "<a@b.com>", ""):
        assert not valid_address(bad)
        with pytest.raises(ValueError):
            build_raw(bad, "s", "b")
    with pytest.raises(ValueError):
        build_raw("a@b.com", "line one\nBcc: x@y.com", "b")


def test_wa_me_link_encodes_hindi_utf8() -> None:
    link = wa_link("919876543210", "नमस्ते, कैसे हैं? 50% off & more")
    assert link == (
        "https://wa.me/919876543210?text="
        "%E0%A4%A8%E0%A4%AE%E0%A4%B8%E0%A5%8D%E0%A4%A4%E0%A5%87%2C%20"
        "%E0%A4%95%E0%A5%88%E0%A4%B8%E0%A5%87%20%E0%A4%B9%E0%A5%88%E0%A4%82%3F%2050%25%20off%20%26%20more"
    )
    assert wa_link("919876543210") == "https://wa.me/919876543210"
    for bad in ("+919876543210", "98765", "0919876543210", "91 98765 43210"):
        with pytest.raises(ValueError):
            wa_link(bad, "x")


async def test_seed_helper_roundtrip(
    registry: PluginRegistry, clock: FixedClock, env: dict[str, str]
) -> None:
    env["GOOGLE_OAUTH_CLIENT_ID"] = "gclient"
    await seed_tokens(registry, clock, age=timedelta(days=6))
    state = await registry.service("google_oauth").state()
    assert (
        state.refresh_expiry_hint_at is not None
        and state.refresh_expiry_hint_at - clock.now() == timedelta(days=1)
    )
