"""Spotify adapter: PKCE, refresh, error mapping, request shapes."""

from __future__ import annotations

import base64
import hashlib
import json
from collections.abc import Callable
from datetime import timedelta
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from sqlalchemy import text

from app.core.clock import FixedClock
from app.music.plugin import music_capabilities
from app.music.service import MusicService
from app.music.spotify import SpotifyError
from app.plugins import PluginRegistry
from tests.conftest import PairedDevice
from tests.music.conftest import API, TOKEN, device, track

Route = Callable[[httpx.Request], httpx.Response]
AddRoute = Callable[[str, str, Route], None]


def challenge_of(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


# ---------------------------------------------------------------- PKCE


async def test_connect_needs_client_id(client: httpx.AsyncClient, paired_device: PairedDevice) -> None:
    r = await client.post("/v1/music/connect", headers=paired_device.headers)
    assert r.status_code == 503 and r.json()["code"] == "requires_credentials"
    status = (await client.get("/v1/music/status", headers=paired_device.headers)).json()
    assert status["spotify"]["state"] == "not_configured"
    assert status["provider_in_use"] == "apple_music"


async def test_pkce_flow_end_to_end(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    env["SPOTIFY_CLIENT_ID"] = "client-123"
    r = await client.post("/v1/music/connect", headers=paired_device.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    url = urlparse(body["authorize_url"])
    q = {k: v[0] for k, v in parse_qs(url.query).items()}
    assert url.netloc == "accounts.spotify.com" and url.path == "/authorize"
    assert q["response_type"] == "code" and q["code_challenge_method"] == "S256"
    assert q["client_id"] == "client-123" and q["state"] == body["state"]
    assert q["redirect_uri"] == body["redirect_uri"] == "http://127.0.0.1:8000/v1/music/callback"
    assert "user-modify-playback-state" in q["scope"].split()
    assert "client_secret" not in url.query

    # the verifier is stored sealed on the server, never sent to the client
    verifier = await registry.service("secrets").get("spotify_pkce", account=body["state"])
    assert verifier and 43 <= len(verifier) <= 128
    assert q["code_challenge"] == challenge_of(verifier) and verifier not in body["authorize_url"]

    route(
        "POST",
        TOKEN,
        lambda req: httpx.Response(
            200, json={"access_token": "AT-new", "refresh_token": "RT-new", "expires_in": 3600, "scope": "x"}
        ),
    )
    cb = await client.get("/v1/music/callback", params={"code": "the-code", "state": body["state"]})
    assert cb.status_code == 200 and "Spotify is connected" in cb.text
    form = parse_qs(seen[-1].content.decode())
    assert form["grant_type"] == ["authorization_code"] and form["code"] == ["the-code"]
    assert form["code_verifier"] == [verifier] and form["client_id"] == ["client-123"]

    # state is single use
    again = await client.get("/v1/music/callback", params={"code": "the-code", "state": body["state"]})
    assert again.status_code == 400 and again.json()["code"] == "callback_invalid"

    # tokens are sealed at rest and reported as connected
    async with registry.service("session_factory")() as s:
        stored = (await s.execute(text("select ciphertext from integration_credentials"))).scalars().all()
    assert stored and all("AT-new" not in c and "RT-new" not in c for c in stored)
    st = (await client.get("/v1/music/status", headers=paired_device.headers)).json()
    assert st["spotify"]["state"] == "connected" and st["provider_in_use"] == "spotify"

    assert (await client.post("/v1/music/disconnect", headers=paired_device.headers)).status_code == 204
    st = (await client.get("/v1/music/status", headers=paired_device.headers)).json()
    assert st["spotify"]["state"] == "not_connected"


async def test_callback_rejects_unknown_state_and_denial(
    client: httpx.AsyncClient, env: dict[str, str]
) -> None:
    env["SPOTIFY_CLIENT_ID"] = "client-123"
    r = await client.get("/v1/music/callback", params={"code": "c", "state": "forged"})
    assert r.status_code == 400 and r.json()["code"] == "callback_invalid"
    r = await client.get("/v1/music/callback", params={"error": "access_denied", "state": "s"})
    assert r.json()["code"] == "spotify_denied"


async def test_pending_authorization_expires(
    client: httpx.AsyncClient, paired_device: PairedDevice, env: dict[str, str], clock: FixedClock
) -> None:
    env["SPOTIFY_CLIENT_ID"] = "client-123"
    state = (await client.post("/v1/music/connect", headers=paired_device.headers)).json()["state"]
    clock.advance(11 * 60)
    r = await client.get("/v1/music/callback", params={"code": "c", "state": state})
    assert r.status_code == 400


# ---------------------------------------------------------------- refresh


async def test_expired_token_is_refreshed_before_use(
    connected: None,
    music: MusicService,
    clock: FixedClock,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    clock.advance(delta=timedelta(hours=2))
    route(
        "POST",
        TOKEN,
        lambda req: httpx.Response(
            200, json={"access_token": "AT-2", "expires_in": 3600}
        ),  # no new refresh token
    )
    route("GET", f"{API}/v1/search", lambda req: httpx.Response(200, json={"tracks": {"items": [track(1)]}}))
    tracks = await music.spotify.search("kesariya", limit=3)
    assert tracks[0]["uri"] == "spotify:track:T1"
    refresh = parse_qs(seen[0].content.decode())
    assert refresh["grant_type"] == ["refresh_token"] and refresh["refresh_token"] == ["RT-1"]
    assert seen[1].headers["authorization"] == "Bearer AT-2"
    assert seen[1].url.params["limit"] == "3" and seen[1].url.params["type"] == "track"
    # the old refresh token is kept when Spotify returns no new one
    clock.advance(delta=timedelta(hours=2))
    await music.spotify.search("again")
    assert parse_qs(seen[-2].content.decode())["refresh_token"] == ["RT-1"]


async def test_401_triggers_one_refresh_then_retry(
    connected: None, music: MusicService, route: AddRoute, seen: list[httpx.Request]
) -> None:
    calls = {"n": 0}

    def search(req: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if req.headers["authorization"] == "Bearer AT-1":
            return httpx.Response(401, json={"error": {"status": 401, "message": "expired"}})
        return httpx.Response(200, json={"tracks": {"items": []}})

    route("GET", f"{API}/v1/search", search)
    route("POST", TOKEN, lambda req: httpx.Response(200, json={"access_token": "AT-9", "expires_in": 3600}))
    assert await music.spotify.search("x") == []
    assert calls["n"] == 2


async def test_refresh_revoked_means_reauthorize(
    connected: None,
    music: MusicService,
    clock: FixedClock,
    route: AddRoute,
) -> None:
    clock.advance(delta=timedelta(hours=2))
    route("POST", TOKEN, lambda req: httpx.Response(400, json={"error": "invalid_grant"}))
    with pytest.raises(SpotifyError) as err:
        await music.spotify.search("x")
    assert err.value.kind == "reauthorize"
    from app.music.api import spotify_status

    assert spotify_status(music.spotify, True).state == "needs_reauthorization"
    caps = {c.id: c for c in music_capabilities(music.spotify)}
    assert caps["music.spotify"].status.value == "manual_user_step"


async def test_second_401_after_refresh_is_reauthorize(
    connected: None, music: MusicService, route: AddRoute
) -> None:
    route("GET", f"{API}/v1/search", lambda req: httpx.Response(401, json={}))
    route("POST", TOKEN, lambda req: httpx.Response(200, json={"access_token": "AT-9", "expires_in": 3600}))
    with pytest.raises(SpotifyError) as err:
        await music.spotify.search("x")
    assert err.value.kind == "reauthorize"


# ---------------------------------------------------------------- error mapping


@pytest.mark.parametrize(
    ("status", "body", "headers", "kind", "retry"),
    [
        (403, {"error": {"status": 403, "message": "Player command failed: Premium required", "reason": "PREMIUM_REQUIRED"}}, {}, "premium_required", None),
        (403, {"error": {"status": 403, "message": "User not registered in the Developer Dashboard"}}, {}, "not_allowlisted", None),
        (403, {"error": {"status": 403, "message": "Forbidden"}}, {}, "forbidden", None),
        (404, {"error": {"status": 404, "message": "No active device", "reason": "NO_ACTIVE_DEVICE"}}, {}, "no_active_device", None),
        (429, {}, {"Retry-After": "7"}, "rate_limited", 7),
        (500, {}, {}, "unavailable", None),
    ],
)  # fmt: skip
async def test_error_mapping(
    connected: None,
    music: MusicService,
    route: AddRoute,
    status: int,
    body: dict[str, object],
    headers: dict[str, str],
    kind: str,
    retry: int | None,
) -> None:
    route("PUT", f"{API}/v1/me/player/pause", lambda req: httpx.Response(status, json=body, headers=headers))
    with pytest.raises(SpotifyError) as err:
        await music.spotify.pause()
    assert err.value.kind == kind and err.value.retry_after_s == retry


async def test_network_failure_is_unavailable(connected: None, music: MusicService) -> None:
    def boom(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down")

    import tests.music.harness as h

    h.ROUTES[("GET", f"{API}/v1/me/player/devices")] = boom
    with pytest.raises(SpotifyError) as err:
        await music.spotify.devices()
    assert err.value.kind == "unavailable"


async def test_not_connected(music: MusicService, env: dict[str, str]) -> None:
    env["SPOTIFY_CLIENT_ID"] = "client-123"
    with pytest.raises(SpotifyError) as err:
        await music.spotify.devices()
    assert err.value.kind == "not_connected"


# ---------------------------------------------------------------- request shapes and mapping


async def test_endpoints_and_bodies(
    connected: None, music: MusicService, route: AddRoute, seen: list[httpx.Request]
) -> None:
    ok = lambda req: httpx.Response(204)  # noqa: E731
    route("PUT", f"{API}/v1/me/player/play", ok)
    route("POST", f"{API}/v1/me/player/next", ok)
    route("POST", f"{API}/v1/me/player/previous", ok)
    route("POST", f"{API}/v1/me/player/queue", ok)
    route("GET", f"{API}/v1/me/player/currently-playing", ok)
    route("GET", f"{API}/v1/me/player/recently-played", lambda req: httpx.Response(200, json={"items": []}))
    route("POST", f"{API}/v1/me/playlists", lambda req: httpx.Response(201, json={"id": "PL1"}))
    route("POST", f"{API}/v1/playlists/PL1/items", lambda req: httpx.Response(201, json={"snapshot_id": "s"}))
    s = music.spotify
    await s.play(device_id="D1", uris=["spotify:track:T1"])
    assert (
        json.loads(seen[-1].content) == {"uris": ["spotify:track:T1"]}
        and seen[-1].url.params["device_id"] == "D1"
    )
    await s.play(context_uri="spotify:album:A1")
    assert json.loads(seen[-1].content) == {"context_uri": "spotify:album:A1"}
    await s.next()
    await s.previous()
    await s.queue("spotify:track:T2", device_id="D1")
    assert seen[-1].url.params["uri"] == "spotify:track:T2"
    assert await s.currently_playing() is None  # 204: nothing playing
    await s.recently_played(limit=99, before_ms=5)
    assert seen[-1].url.params["limit"] == "50" and seen[-1].url.params["before"] == "5"
    assert "after" not in seen[-1].url.params
    playlist = await s.create_playlist("Mix", description="d", public=False)
    assert json.loads(seen[-1].content) == {"name": "Mix", "description": "d", "public": False}
    assert await s.add_tracks(playlist["id"], [f"spotify:track:T{i}" for i in range(230)]) == 230
    adds = [r for r in seen if r.url.path.endswith("/items")]
    assert [len(json.loads(r.content)["uris"]) for r in adds] == [100, 100, 30]  # Spotify's 100 limit
    paths = {r.url.path for r in seen}
    banned = ("recommendations", "audio-features", "audio-analysis", "related-artists")
    assert not any(b in p for p in paths for b in banned)


async def test_transfer_takes_exactly_one_device_id(
    connected: None, music: MusicService, route: AddRoute, seen: list[httpx.Request]
) -> None:
    route("PUT", f"{API}/v1/me/player", lambda req: httpx.Response(204))
    await music.spotify.transfer("DEV1", play=False)
    assert json.loads(seen[-1].content) == {"device_ids": ["DEV1"], "play": False}
    for bad in ("A,B", "", "   "):
        with pytest.raises(ValueError):
            await music.spotify.transfer(bad)
    assert len(seen) == 1  # nothing sent for the refused calls


async def test_devices_mapping(connected: None, music: MusicService, route: AddRoute) -> None:
    route(
        "GET",
        f"{API}/v1/me/player/devices",
        lambda req: httpx.Response(200, json={"devices": [device("D1", "Mac", "Computer", True)]}),
    )
    raw = await music.spotify.devices()
    assert raw[0]["id"] == "D1"
