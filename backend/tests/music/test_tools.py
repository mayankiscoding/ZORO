"""Music tools through the real executor: plans, device targeting, history, playlists, session."""

from __future__ import annotations

import json
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

import httpx

from app.core.types import DevicePlatform
from app.music.schemas import MusicResult, PlaylistOut, RecentOut, SearchOut
from app.plugins import PluginRegistry
from app.tools import Completed, ToolExecutor
from tests.conftest import PairedDevice
from tests.music.conftest import API, ctx_for, device, track

Route = Callable[[httpx.Request], httpx.Response]
AddRoute = Callable[[str, str, Route], None]
OK = lambda req: httpx.Response(204)  # noqa: E731


async def run(
    registry: PluginRegistry,
    paired: PairedDevice,
    tool: str,
    args: dict[str, Any],
    call: str,
    lang: str = "en",
) -> Completed:
    ctx = ctx_for(registry, device_id=paired.device_id, lang=lang)
    outcome = await registry.service("tool_executor").execute(ctx, tool, args, call_id=call)
    assert isinstance(outcome, Completed), outcome
    return outcome


def specs(registry: PluginRegistry) -> dict[str, Any]:
    return {s.name: s for s in registry.tools.for_group("music-mcp")}


async def test_tool_metadata(registry: PluginRegistry) -> None:
    tools = specs(registry)
    assert set(tools) == {
        "music.search", "music.play", "music.pause", "music.skip", "music.transfer",
        "music.recently_played", "music.create_playlist",
    }  # fmt: skip
    assert tools["music.search"].risk.value == "low" and tools["music.recently_played"].risk.value == "low"
    assert tools["music.create_playlist"].risk.value == "medium"
    for spec in tools.values():
        assert spec.summarizer and spec.permission and spec.data_classes and spec.mcp_group == "music-mcp"


async def test_search_maps_tracks_and_keeps_working_set(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    route(
        "GET",
        f"{API}/v1/search",
        lambda r: httpx.Response(200, json={"tracks": {"items": [track(1), track(2)]}}),
    )
    done = await run(registry, paired_device, "music.search", {"query": "kesariya", "limit": 2}, "s1")
    out = done.result
    assert isinstance(out, SearchOut) and out.status == "ok"
    assert (
        out.tracks[0].title == "Song 1"
        and out.tracks[0].artists == ["Artist 1"]
        and out.tracks[0].album == "Album 1"
    )
    assert done.summary == "I found 2 songs. First: Song 1 - Artist 1."
    assert done.card is not None and done.card.kind == "music"
    ctx = ctx_for(registry)
    assert [t["uri"] for t in await ctx.working_set("tracks")] == ["spotify:track:T1", "spotify:track:T2"]
    session = await registry.service("music").session.get()
    assert session.last_query == "kesariya" and session.provider == "spotify"


async def test_similar_songs_use_search_and_say_so(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    route("GET", f"{API}/v1/search", lambda r: httpx.Response(200, json={"tracks": {"items": [track(1)]}}))
    for lang, needle in (
        ("en", "no longer offers recommendations"),
        ("hinglish", "recommendations nahi deta"),
        ("hi", "सुझाव नहीं देता"),
    ):
        done = await run(
            registry,
            paired_device,
            "music.search",
            {"query": "Tum Hi Ho", "similar_to": True},
            f"sim-{lang}",
            lang,
        )
        assert done.summary is not None and needle in done.summary
    assert {r.url.path for r in seen} == {"/v1/search"}


async def test_search_not_connected_is_honest(
    registry: PluginRegistry, paired_device: PairedDevice, env: dict[str, str], seen: list[httpx.Request]
) -> None:
    done = await run(registry, paired_device, "music.search", {"query": "x"}, "n1")
    assert (
        isinstance(done.result, SearchOut)
        and done.result.status == "not_configured"
        and done.result.tracks == []
    )
    assert done.summary == "Spotify is not set up on the server yet."
    env["SPOTIFY_CLIENT_ID"] = "c"
    done = await run(registry, paired_device, "music.search", {"query": "x"}, "n2", "hinglish")
    assert done.result.status == "not_connected"  # type: ignore[attr-defined]
    assert done.summary is not None and "connect nahi hai" in done.summary
    assert seen == []


async def test_apple_music_plan_when_spotify_not_connected(
    registry: PluginRegistry, paired_device: PairedDevice, seen: list[httpx.Request]
) -> None:
    done = await run(registry, paired_device, "music.play", {"query": "Kesariya", "target": "mac"}, "p1")
    r = done.result
    assert isinstance(r, MusicResult) and r.status == "device_plan" and r.provider == "apple_music"
    (step,) = r.follow_ups  # the one convention for "run this next" (app.tools.followup)
    assert step.tool == "device.music.control"
    assert step.args == {"provider": "apple_music", "action": "search_play", "query": "Kesariya"}
    assert step.target_platform is DevicePlatform.MACOS
    assert done.follow_ups == (step,)  # the executor hands them to the orchestrator
    pause = await run(registry, paired_device, "music.pause", {}, "p2")
    assert pause.result.follow_ups[0].args == {"provider": "apple_music", "action": "pause"}  # type: ignore[attr-defined]
    skip = await run(
        registry, paired_device, "music.skip", {"direction": "previous", "target": "iphone"}, "p3"
    )
    assert skip.result.follow_ups[0].args["action"] == "previous"  # type: ignore[attr-defined]
    assert skip.result.follow_ups[0].target_platform is DevicePlatform.IOS  # type: ignore[attr-defined]
    assert seen == []


async def test_session_preference_forces_device_plan(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    client: httpx.AsyncClient,
    seen: list[httpx.Request],
) -> None:
    r = await client.put("/v1/music/session", headers=paired_device.headers, json={"provider": "apple_music"})
    assert r.status_code == 200 and r.json()["updated_by"] == paired_device.device_id
    done = await run(registry, paired_device, "music.play", {"query": "x"}, "pp")
    assert done.result.status == "device_plan"  # type: ignore[attr-defined]
    assert seen == []
    back = await client.put(
        "/v1/music/session",
        headers=paired_device.headers,
        json={"provider": None, "active_device": {"name": "MacBook", "type": "Computer"}},
    )
    assert back.json()["provider"] is None and back.json()["active_device"]["name"] == "MacBook"
    assert (await client.get("/v1/music/session", headers=paired_device.headers)).json()["active_device"][
        "name"
    ] == "MacBook"


async def test_play_on_my_mac_picks_one_device(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    devices = [
        device("PHONE", "Aman's iPhone", "Smartphone"),
        device("MAC", "Aman's MacBook Pro", "Computer"),
        device("TV", "Living room", "TV"),
    ]
    route("GET", f"{API}/v1/me/player/devices", lambda r: httpx.Response(200, json={"devices": devices}))
    route("GET", f"{API}/v1/search", lambda r: httpx.Response(200, json={"tracks": {"items": [track(5)]}}))
    route("PUT", f"{API}/v1/me/player/play", OK)
    done = await run(registry, paired_device, "music.play", {"query": "kesariya", "target": "mac"}, "m1")
    r = done.result
    assert isinstance(r, MusicResult) and r.status == "ok" and r.device is not None and r.device.id == "MAC"
    play = seen[-1]
    assert play.url.params["device_id"] == "MAC" and json.loads(play.content) == {
        "uris": ["spotify:track:T5"]
    }
    assert done.summary == "Playing Song 5 - Artist 5 on Aman's MacBook Pro."
    session = await registry.service("music").session.get()
    assert session.active_device is not None and session.active_device.id == "MAC"
    assert (
        session.last_query == "kesariya"
        and session.last_track is not None
        and session.last_track.uri == "spotify:track:T5"
    )


async def test_ambiguous_or_missing_device_sends_nothing(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    two_macs = [device("M1", "Office Mac", "Computer"), device("M2", "Home Mac", "Computer")]
    route("GET", f"{API}/v1/me/player/devices", lambda r: httpx.Response(200, json={"devices": two_macs}))
    done = await run(registry, paired_device, "music.transfer", {"target": "mac"}, "t1")
    assert done.result.status == "choose_device" and len(done.result.devices) == 2  # type: ignore[attr-defined]
    assert done.summary is not None and "Office Mac" in done.summary and "Home Mac" in done.summary
    none_found = await run(registry, paired_device, "music.transfer", {"target": "iphone"}, "t2")
    assert none_found.result.status == "device_not_found"  # type: ignore[attr-defined]
    assert not [r for r in seen if r.method == "PUT"]  # no transfer attempted


async def test_transfer_sends_exactly_one_device_id(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    route(
        "GET",
        f"{API}/v1/me/player/devices",
        lambda r: httpx.Response(
            200,
            json={
                "devices": [
                    device("PHONE", "Aman's iPhone", "Smartphone"),
                    device("MAC", "MacBook", "Computer"),
                ]
            },
        ),
    )
    route("PUT", f"{API}/v1/me/player", OK)
    done = await run(registry, paired_device, "music.transfer", {"target": "iphone"}, "t3")
    assert done.result.status == "ok"  # type: ignore[attr-defined]
    put = [r for r in seen if r.method == "PUT"]
    assert len(put) == 1 and json.loads(put[0].content) == {"device_ids": ["PHONE"], "play": True}


async def test_no_active_device_and_premium_paths(
    registry: PluginRegistry, paired_device: PairedDevice, connected: None, route: AddRoute
) -> None:
    route(
        "GET",
        f"{API}/v1/me/player/devices",
        lambda r: httpx.Response(200, json={"devices": [device("D", "Speaker", "Speaker")]}),
    )
    route(
        "PUT",
        f"{API}/v1/me/player/pause",
        lambda r: httpx.Response(404, json={"error": {"reason": "NO_ACTIVE_DEVICE", "message": "x"}}),
    )
    done = await run(registry, paired_device, "music.pause", {}, "e1")
    assert done.result.status == "no_active_device" and done.result.devices[0].id == "D"  # type: ignore[attr-defined]
    assert done.summary is not None and "No Spotify device is active" in done.summary
    route(
        "POST",
        f"{API}/v1/me/player/next",
        lambda r: httpx.Response(
            403, json={"error": {"reason": "PREMIUM_REQUIRED", "message": "Premium required"}}
        ),
    )
    done = await run(registry, paired_device, "music.skip", {}, "e2", "hi")
    assert (
        done.result.status == "premium_required" and done.summary == "प्लेबैक कंट्रोल के लिए Spotify Premium चाहिए।"
    )  # type: ignore[attr-defined]
    route(
        "POST",
        f"{API}/v1/me/player/previous",
        lambda r: httpx.Response(429, headers={"Retry-After": "12"}, json={}),
    )
    done = await run(registry, paired_device, "music.skip", {"direction": "previous"}, "e3")
    assert done.result.status == "rate_limited" and done.result.retry_after_s == 12  # type: ignore[attr-defined]
    assert done.summary is not None and "12 seconds" in done.summary


async def test_play_the_song_i_was_listening_to_yesterday(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    # clock: 2026-11-13 10:00 UTC = 15:30 IST. Yesterday in IST starts 2026-11-11T18:30Z.
    items = [
        {"track": track(7, "Late"), "played_at": "2026-11-12T17:00:00.000Z"},
        {"track": track(8, "Earlier"), "played_at": "2026-11-12T03:00:00.000Z"},
        {"track": track(9, "Old"), "played_at": "2026-11-11T10:00:00.000Z"},  # the day before: excluded
    ]
    route("GET", f"{API}/v1/me/player/recently-played", lambda r: httpx.Response(200, json={"items": items}))
    route("PUT", f"{API}/v1/me/player/play", OK)
    done = await run(registry, paired_device, "music.play", {"from_history": "yesterday"}, "h1")
    assert done.result.status == "ok" and done.result.track.uri == "spotify:track:T7"  # type: ignore[attr-defined]
    hist = next(r for r in seen if r.url.path.endswith("recently-played"))
    assert hist.url.params["before"] == str(
        int(datetime(2026, 11, 12, 18, 30, tzinfo=UTC).timestamp() * 1000)
    )
    assert json.loads(seen[-1].content) == {"uris": ["spotify:track:T7"]}
    listed = await run(registry, paired_device, "music.recently_played", {"day": "yesterday"}, "h2")
    assert isinstance(listed.result, RecentOut) and [t.uri for t in listed.result.tracks] == [
        "spotify:track:T7",
        "spotify:track:T8",
    ]


async def test_history_empty_says_spotify_keeps_50(
    registry: PluginRegistry, paired_device: PairedDevice, connected: None, route: AddRoute
) -> None:
    route("GET", f"{API}/v1/me/player/recently-played", lambda r: httpx.Response(200, json={"items": []}))
    done = await run(registry, paired_device, "music.recently_played", {"day": "yesterday"}, "h3")
    assert done.result.status == "nothing_found"  # type: ignore[attr-defined]
    assert done.summary == "Nothing found. Spotify only keeps your last 50 plays."


async def test_play_second_result_from_working_set(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    route(
        "GET",
        f"{API}/v1/search",
        lambda r: httpx.Response(200, json={"tracks": {"items": [track(1), track(2), track(3)]}}),
    )
    route("PUT", f"{API}/v1/me/player/play", OK)
    await run(registry, paired_device, "music.search", {"query": "x"}, "w1")
    done = await run(registry, paired_device, "music.play", {"ref": 2}, "w2")
    assert done.result.track.uri == "spotify:track:T2"  # type: ignore[attr-defined]
    missing = await run(registry, paired_device, "music.play", {"ref": 9}, "w3")
    assert missing.result.status == "nothing_found"  # type: ignore[attr-defined]


async def test_create_playlist_runs_once_per_call_id(
    registry: PluginRegistry,
    paired_device: PairedDevice,
    connected: None,
    route: AddRoute,
    seen: list[httpx.Request],
) -> None:
    route(
        "POST",
        f"{API}/v1/me/playlists",
        lambda r: httpx.Response(
            201, json={"id": "PL9", "external_urls": {"spotify": "https://open.spotify.com/playlist/PL9"}}
        ),
    )
    route("POST", f"{API}/v1/playlists/PL9/items", lambda r: httpx.Response(201, json={"snapshot_id": "s"}))
    args = {"name": "Road Trip", "track_uris": ["spotify:track:T1", "spotify:track:T2"]}
    first = await run(registry, paired_device, "music.create_playlist", args, "pl1")
    assert (
        isinstance(first.result, PlaylistOut)
        and first.result.added == 2
        and first.result.playlist_id == "PL9"
    )
    assert first.summary == "Playlist Road Trip created with 2 songs."
    again = await run(
        registry, paired_device, "music.create_playlist", args, "pl1"
    )  # replay of the same call
    assert again.result == first.result
    assert len([r for r in seen if r.url.path == "/v1/me/playlists"]) == 1
    body = json.loads(next(r for r in seen if r.url.path.endswith("/items")).content)
    assert body == {"uris": ["spotify:track:T1", "spotify:track:T2"]}


async def test_invalid_arguments_are_rejected_before_any_call(
    registry: PluginRegistry, paired_device: PairedDevice, connected: None, seen: list[httpx.Request]
) -> None:
    executor: ToolExecutor = registry.service("tool_executor")
    ctx = ctx_for(registry, device_id=paired_device.device_id)
    for tool, args in (
        ("music.play", {"uri": "https://evil.example/x"}),
        ("music.transfer", {}),
        ("music.create_playlist", {"name": "x", "track_uris": ["not-a-uri"]}),
    ):
        outcome = await executor.execute(ctx, tool, args, call_id=f"bad-{tool}")
        assert outcome.__class__.__name__ == "Failed"
    assert seen == []


async def test_capabilities_are_honest(registry: PluginRegistry, env: dict[str, str]) -> None:
    caps = {c.id: c for c in registry.capabilities.all(domain="music")}
    assert caps["music.spotify"].status.value == "requires_credentials"
    assert caps["music.recommendations"].status.value == "unavailable"
    assert caps["music.apple_music"].status.value == "manual_user_step"
    env["SPOTIFY_CLIENT_ID"] = "c"
    assert {c.id: c for c in registry.capabilities.all(domain="music")}[
        "music.spotify"
    ].status.value == "manual_user_step"
