"""Music tools. Playback controls are MEDIUM (journaled: a repeated skip must not run twice); search and
history are LOW and read-only."""

from __future__ import annotations

from typing import Any

from app.core.types import AgentId, DataClass, RiskLevel
from app.music import speech
from app.music.schemas import (
    MusicResult,
    PauseIn,
    PlayIn,
    PlaylistIn,
    PlaylistOut,
    RecentIn,
    RecentOut,
    SearchIn,
    SearchOut,
    SkipIn,
    TransferIn,
)
from app.music.service import MusicService
from app.schemas.common import LabelValue
from app.tools.spec import ApprovalView, ToolContext, ToolSpec

PERM_READ = "music.read"
PERM_CONTROL = "music.control"
PERM_PLAYLISTS = "music.playlists"
PERMISSIONS = (
    (PERM_READ, "Let ZORO search music and read your recent plays", True),
    (PERM_CONTROL, "Let ZORO play, pause, skip and move music between devices", True),
    (PERM_PLAYLISTS, "Let ZORO create playlists in your music account", True),
)
AGENTS = frozenset({AgentId.MUSIC, AgentId.PERSONAL_ASSISTANT, AgentId.SUPERVISOR, AgentId.VOICE})
_PERSONAL = frozenset({DataClass.PERSONAL})
TRACKS = "tracks"


async def _remember(ctx: ToolContext, tracks: list[Any]) -> None:
    await ctx.set_working_set(TRACKS, [t.model_dump(mode="json") for t in tracks])


def _playlist_view(args: PlaylistIn) -> ApprovalView:
    shown = "last shown songs" if args.use_last_search else f"{len(args.track_uris)} songs"
    return ApprovalView(
        title=f"Create the playlist “{args.name}”",
        summary=f"{args.name} ({'public' if args.public else 'private'}, {shown})",
        details=(
            LabelValue(label="Name", value=args.name),
            LabelValue(label="Visibility", value="public" if args.public else "private"),
            LabelValue(label="Songs", value=shown),
        ),
    )


def build_tools(service: MusicService) -> list[ToolSpec]:
    async def search(ctx: ToolContext, args: SearchIn) -> SearchOut:
        out = await service.search(args.query, args.limit, args.similar_to)
        if out.tracks:
            await _remember(ctx, out.tracks)
        return out

    async def play(ctx: ToolContext, args: PlayIn) -> MusicResult:
        return await service.play(
            args, working_tracks=await ctx.working_set(TRACKS), now=ctx.now(), tz=ctx.timezone
        )

    async def pause(ctx: ToolContext, args: PauseIn) -> MusicResult:
        return await service.pause(args.target)

    async def skip(ctx: ToolContext, args: SkipIn) -> MusicResult:
        return await service.skip(args.direction, args.target)

    async def transfer(ctx: ToolContext, args: TransferIn) -> MusicResult:
        return await service.transfer(args.target, args.play)

    async def recent(ctx: ToolContext, args: RecentIn) -> RecentOut:
        out = await service.recently_played(args.limit, args.day, ctx.now(), ctx.timezone)
        if out.tracks:
            await _remember(ctx, out.tracks)
        return out

    async def playlist(ctx: ToolContext, args: PlaylistIn) -> PlaylistOut:
        return await service.create_playlist(args, await ctx.working_set(TRACKS))

    def spec(
        name: str,
        description: str,
        inp: type,
        out: type,
        handler: Any,
        risk: RiskLevel,
        perm: str,
        summarizer: Any,
        **extra: Any,
    ) -> ToolSpec:
        return ToolSpec(
            name=name,
            description=description,
            input_model=inp,
            output_model=out,
            handler=handler,
            risk=risk,
            data_classes=_PERSONAL,
            permission=perm,
            agents=AGENTS,
            mcp_group="music-mcp",
            summarizer=summarizer,
            **extra,
        )

    return [
        spec("music.search", "Search songs on Spotify. For 'songs like X' it searches X and says so "
             "(Spotify removed recommendations).", SearchIn, SearchOut, search, RiskLevel.LOW, PERM_READ,
             speech.search_summary, card=speech.music_card),
        spec("music.play", "Play a song, album, playlist, the last search result, or a song from listening "
             "history, optionally on 'mac' or 'iphone'. Uses Spotify when connected, else returns a "
             "device.music.control plan.", PlayIn, MusicResult, play, RiskLevel.MEDIUM, PERM_CONTROL,
             speech.play_summary, card=speech.music_card),
        spec("music.pause", "Pause music.", PauseIn, MusicResult, pause, RiskLevel.MEDIUM, PERM_CONTROL,
             speech.pause_summary),
        spec("music.skip", "Skip to the next or previous song.", SkipIn, MusicResult, skip,
             RiskLevel.MEDIUM, PERM_CONTROL, speech.skip_summary),
        spec("music.transfer", "Move Spotify playback to exactly one device ('mac', 'iphone' or a device name).",
             TransferIn, MusicResult, transfer, RiskLevel.MEDIUM, PERM_CONTROL, speech.transfer_summary),
        spec("music.recently_played", "List recently played songs (Spotify keeps the last 50), optionally "
             "only today or yesterday.", RecentIn, RecentOut, recent, RiskLevel.LOW, PERM_READ,
             speech.recent_summary, card=speech.music_card),
        spec("music.create_playlist", "Create a Spotify playlist and add songs.", PlaylistIn, PlaylistOut,
             playlist, RiskLevel.MEDIUM, PERM_PLAYLISTS, speech.playlist_summary, approval_view=_playlist_view,
             timeout_s=30),
    ]  # fmt: skip
