"""MusicService: provider planning, device targeting and the Spotify-backed actions.

The plan is: Spotify when it is connected (and the owner did not pick Apple Music), otherwise a
`device.music.control` call the device runs itself (Apple Music, or the Spotify app by URL).
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from app.core.types import DevicePlatform
from app.music.schemas import (
    MusicDevice,
    MusicResult,
    MusicTrack,
    PlayIn,
    PlaylistIn,
    PlaylistOut,
    RecentOut,
    SearchOut,
    SessionDevice,
    Status,
)
from app.music.session import MusicSessionService
from app.music.spotify import SpotifyClient, SpotifyError
from app.tools.followup import FollowUp

_ERROR_STATUS: dict[str, Status] = {
    "not_configured": "not_configured",
    "not_connected": "not_connected",
    "reauthorize": "needs_reauth",
    "premium_required": "premium_required",
    "not_allowlisted": "not_allowed",
    "forbidden": "not_allowed",
    "no_active_device": "no_active_device",
    "rate_limited": "rate_limited",
}
_PLATFORM = {"mac": "macos", "iphone": "ios"}
_MAC_WORDS = ("mac", "macbook", "imac", "my mac", "computer", "laptop")
_PHONE_WORDS = ("iphone", "my iphone", "phone", "smartphone", "my phone")


def to_track(raw: dict[str, Any], played_at: str | None = None) -> MusicTrack:
    artists = [
        str(a.get("name", "")) for a in raw.get("artists", []) if isinstance(a, dict) and a.get("name")
    ]
    album = raw.get("album", {}).get("name") if isinstance(raw.get("album"), dict) else None
    return MusicTrack.model_validate(
        {
            "uri": raw["uri"],
            "title": raw.get("name", ""),
            "artists": artists,
            "album": album,
            "played_at": played_at,
        }
    )


def to_device(raw: dict[str, Any]) -> MusicDevice:
    volume = raw.get("volume_percent")
    return MusicDevice(
        id=str(raw.get("id", "")),
        name=str(raw.get("name", "")),
        type=str(raw.get("type", "")),
        is_active=bool(raw.get("is_active", False)),
        volume_percent=int(volume) if isinstance(volume, int) else None,
    )


def resolve_device(
    devices: Sequence[MusicDevice], target: str
) -> tuple[MusicDevice | None, list[MusicDevice], str]:
    """Pick exactly one device for "on my Mac" / "on my iPhone" / a device name.

    Returns (device, candidates, outcome) with outcome "ok", "choose" (several fit) or "none"."""
    wanted = target.strip().lower()
    usable = [d for d in devices if d.id]
    if wanted in _MAC_WORDS:
        kind, key = "computer", "mac"
    elif wanted in _PHONE_WORDS:
        kind, key = "smartphone", "iphone"
    else:
        exact = [d for d in usable if d.name.lower() == wanted]
        found = exact or [d for d in usable if wanted in d.name.lower()]
        return _one(found)
    found = [d for d in usable if d.type.lower() == kind or key in d.name.lower()]
    if len(found) > 1:
        named = [d for d in found if key in d.name.lower()]
        if len(named) == 1:
            found = named
    return _one(found)


def _one(found: list[MusicDevice]) -> tuple[MusicDevice | None, list[MusicDevice], str]:
    if len(found) == 1:
        return found[0], found, "ok"
    return None, found, "choose" if found else "none"


def apple_plan(action: str, *, query: str | None = None, target: str | None = None) -> MusicResult:
    """What to run on the device when Spotify is not the provider."""
    args: dict[str, Any] = {"provider": "apple_music", "action": action}
    if query:
        args["query"] = query
    platform = _PLATFORM.get(_target_kind(target)) if target else None
    return MusicResult(
        status="device_plan",
        provider="apple_music",
        follow_ups=[
            FollowUp(
                tool="device.music.control",
                args=args,
                target_platform=DevicePlatform(platform) if platform else None,
            )
        ],
    )


def _target_kind(target: str | None) -> str:
    wanted = (target or "").lower()
    if wanted in _MAC_WORDS:
        return "mac"
    return "iphone" if wanted in _PHONE_WORDS else ""


def failure(error: SpotifyError, **extra: Any) -> dict[str, Any]:
    status: Status = _ERROR_STATUS.get(error.kind, "unavailable")
    return {"status": status, "provider": "spotify", "retry_after_s": error.retry_after_s, **extra}


class MusicService:
    def __init__(self, spotify: SpotifyClient, session: MusicSessionService) -> None:
        self.spotify = spotify
        self.session = session

    async def provider(self) -> str:
        """ "spotify" or "apple_music" (the device plan); "none" when nothing can play."""
        preference = (await self.session.get()).provider
        if preference == "apple_music":
            return "apple_music"
        if await self.spotify.is_connected():
            return "spotify"
        return "apple_music"

    async def _not_ready(self) -> dict[str, Any] | None:
        if not self.spotify.configured:
            return {"status": "not_configured", "provider": "none"}
        if not await self.spotify.is_connected():
            return {"status": "not_connected", "provider": "none"}
        return None

    async def _device(self, target: str | None) -> tuple[MusicDevice | None, dict[str, Any] | None]:
        """(device, early result). No target: no device id (Spotify uses its active device)."""
        if target is None:
            return None, None
        devices = [to_device(d) for d in await self.spotify.devices()]
        device, candidates, outcome = resolve_device(devices, target)
        if device is not None:
            return device, None
        status: Status = "choose_device" if outcome == "choose" else "device_not_found"
        return None, {"status": status, "provider": "spotify", "devices": candidates or devices}

    # ------------------------------------------------------------ search

    async def search(self, query: str, limit: int, similar_to: bool) -> SearchOut:
        if (blocked := await self._not_ready()) is not None:
            return SearchOut(**blocked, query=query, similar_to=similar_to)
        try:
            tracks = [to_track(t) for t in await self.spotify.search(query, limit=limit)]
        except SpotifyError as exc:
            return SearchOut(**failure(exc), query=query, similar_to=similar_to)
        await self.session.played(provider="spotify", device=None, query=query, track=None)
        return SearchOut(
            status="ok" if tracks else "nothing_found",
            provider="spotify",
            query=query,
            similar_to=similar_to,
            tracks=tracks,
        )

    # ------------------------------------------------------------ playback

    async def play(
        self, args: PlayIn, *, working_tracks: Sequence[dict[str, Any]], now: datetime, tz: str
    ) -> MusicResult:
        if await self.provider() == "apple_music":
            if args.from_history or args.ref or (args.uri and not args.query):
                return MusicResult(
                    status="unsupported",
                    provider="apple_music",
                    message="history_and_selection_need_spotify",
                )
            return apple_plan("search_play" if args.query else "play", query=args.query, target=args.target)
        try:
            device, early = await self._device(args.target)
            if early is not None:
                return MusicResult(**early)
            uri, track, query = await self._what(args, working_tracks, now, tz)
            if uri is None and (args.query or args.from_history or args.ref):
                return MusicResult(status="nothing_found", provider="spotify")
            device_id = device.id if device else None
            if uri is None:
                await self.spotify.play(device_id=device_id)  # resume
            elif uri.startswith("spotify:track:") or uri.startswith("spotify:episode:"):
                await self.spotify.play(device_id=device_id, uris=[uri])
            else:
                await self.spotify.play(device_id=device_id, context_uri=uri)
        except SpotifyError as exc:
            extra: dict[str, Any] = {}
            if exc.kind == "no_active_device":
                extra["devices"] = await self._safe_devices()
            return MusicResult(**failure(exc, **extra))
        await self.session.played(
            provider="spotify",
            device=SessionDevice(id=device.id, name=device.name, type=device.type) if device else None,
            query=query,
            track=track,
        )
        return MusicResult(status="ok", provider="spotify", track=track, device=device)

    async def _safe_devices(self) -> list[MusicDevice]:
        try:
            return [to_device(d) for d in await self.spotify.devices()]
        except SpotifyError:
            return []

    async def _what(
        self, args: PlayIn, working: Sequence[dict[str, Any]], now: datetime, tz: str
    ) -> tuple[str | None, MusicTrack | None, str | None]:
        """(uri to play, the track when known, the query to remember)."""
        if args.uri:
            return args.uri, None, None
        if args.ref:
            if args.ref > len(working):
                return None, None, None
            picked = MusicTrack.model_validate(working[args.ref - 1])
            return picked.uri, picked, None
        if args.from_history:
            recent = await self._history(args.from_history, 50 if args.from_history != "last" else 1, now, tz)
            if recent:
                return recent[0].uri, recent[0], None
            return None, None, None
        if args.query:
            found = await self.spotify.search(args.query, limit=1)
            if not found:
                return None, None, args.query
            track = to_track(found[0])
            return track.uri, track, args.query
        return None, None, None

    async def _history(self, day: str, limit: int, now: datetime, tz: str) -> list[MusicTrack]:
        zone = ZoneInfo(tz)
        local = now.astimezone(zone)
        today = local.replace(hour=0, minute=0, second=0, microsecond=0)
        lower: datetime | None = None
        before_ms: int | None = None
        if day == "yesterday":
            lower = today - timedelta(days=1)
            before_ms = int(today.timestamp() * 1000)
        elif day == "today":
            lower = today
        items = await self.spotify.recently_played(limit=limit, before_ms=before_ms)
        out: list[MusicTrack] = []
        for item in items:
            track_raw = item.get("track")
            if not isinstance(track_raw, dict) or not track_raw.get("uri"):
                continue
            played_at = item.get("played_at")
            if lower is not None and (
                not isinstance(played_at, str) or datetime.fromisoformat(played_at) < lower
            ):
                continue
            out.append(to_track(track_raw, played_at if isinstance(played_at, str) else None))
        return out

    async def recently_played(self, limit: int, day: str | None, now: datetime, tz: str) -> RecentOut:
        if (blocked := await self._not_ready()) is not None:
            return RecentOut(**blocked, day=day)
        try:
            tracks = (
                await self._history(day or "last", limit, now, tz)
                if day
                else await self._history("all", limit, now, tz)
            )
        except SpotifyError as exc:
            return RecentOut(**failure(exc), day=day)
        return RecentOut(
            status="ok" if tracks else "nothing_found",
            provider="spotify",
            day=day,
            tracks=tracks[:limit],
            message="" if tracks else "spotify_keeps_last_50",
        )

    async def pause(self, target: str | None) -> MusicResult:
        if await self.provider() == "apple_music":
            return apple_plan("pause", target=target)
        return await self._control("pause", target)

    async def skip(self, direction: str, target: str | None) -> MusicResult:
        if await self.provider() == "apple_music":
            return apple_plan(direction, target=target)
        return await self._control(direction, target)

    async def _control(self, action: str, target: str | None) -> MusicResult:
        try:
            device, early = await self._device(target)
            if early is not None:
                return MusicResult(**early)
            device_id = device.id if device else None
            if action == "pause":
                await self.spotify.pause(device_id=device_id)
            elif action == "next":
                await self.spotify.next(device_id=device_id)
            else:
                await self.spotify.previous(device_id=device_id)
        except SpotifyError as exc:
            extra = {"devices": await self._safe_devices()} if exc.kind == "no_active_device" else {}
            return MusicResult(**failure(exc, **extra))
        if device is not None:
            await self.session.played(
                provider="spotify",
                device=SessionDevice(id=device.id, name=device.name, type=device.type),
                query=None,
                track=None,
            )
        return MusicResult(status="ok", provider="spotify", device=device)

    async def transfer(self, target: str, play: bool) -> MusicResult:
        if (blocked := await self._not_ready()) is not None:
            return MusicResult(**blocked)
        try:
            device, early = await self._device(target)
            if early is not None:
                return MusicResult(**early)
            assert device is not None
            await self.spotify.transfer(device.id, play=play)  # exactly one device id
        except SpotifyError as exc:
            return MusicResult(**failure(exc))
        await self.session.played(
            provider="spotify",
            device=SessionDevice(id=device.id, name=device.name, type=device.type),
            query=None,
            track=None,
        )
        return MusicResult(status="ok", provider="spotify", device=device)

    # ------------------------------------------------------------ playlists

    async def create_playlist(
        self, args: PlaylistIn, working_tracks: Sequence[dict[str, Any]]
    ) -> PlaylistOut:
        if (blocked := await self._not_ready()) is not None:
            return PlaylistOut(**blocked, name=args.name)
        uris = list(args.track_uris)
        if args.use_last_search:
            uris += [str(t["uri"]) for t in working_tracks if t.get("uri") and t["uri"] not in uris]
        uris = uris[:100]
        try:
            playlist = await self.spotify.create_playlist(
                args.name, description=args.description, public=args.public
            )
            added = await self.spotify.add_tracks(str(playlist["id"]), uris) if uris else 0
        except SpotifyError as exc:
            return PlaylistOut(**failure(exc), name=args.name)
        url = (
            playlist.get("external_urls", {}).get("spotify")
            if isinstance(playlist.get("external_urls"), dict)
            else None
        )
        return PlaylistOut(
            status="ok",
            provider="spotify",
            playlist_id=str(playlist["id"]),
            name=args.name,
            url=url,
            added=added,
        )
