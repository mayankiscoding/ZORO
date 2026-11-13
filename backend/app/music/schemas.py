"""Typed inputs and outputs of the music tools and routers."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field

from app.tools.followup import FollowUp

Provider = Literal["spotify", "apple_music", "none"]
Status = Literal[
    "ok",
    "device_plan",  # Apple Music: the device tool call to run is the result's follow-up
    "not_connected",
    "needs_reauth",
    "not_configured",
    "premium_required",
    "not_allowed",
    "no_active_device",
    "choose_device",
    "device_not_found",
    "nothing_found",
    "rate_limited",
    "unsupported",
    "unavailable",
]


class _Out(BaseModel):
    model_config = ConfigDict(extra="ignore")


class MusicTrack(_Out):
    uri: str
    title: str
    artists: list[str] = Field(default_factory=list)
    album: str | None = None
    played_at: AwareDatetime | None = None


class MusicDevice(_Out):
    id: str
    name: str
    type: str = ""
    is_active: bool = False
    volume_percent: int | None = None


class MusicResult(_Out):
    status: Status
    provider: Provider = "none"
    message: str = ""
    track: MusicTrack | None = None
    device: MusicDevice | None = None
    devices: list[MusicDevice] = Field(default_factory=list)
    # Apple Music is played by the device, not the backend: the device tool call to run next
    # (`app.tools.followup`), aimed at the platform the owner named.
    follow_ups: list[FollowUp] = Field(default_factory=list)
    retry_after_s: int | None = None


# ---------------------------------------------------------------- tool inputs


class _In(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)


Target = Annotated[str, Field(min_length=1, max_length=80)]


class SearchIn(_In):
    query: Annotated[str, Field(min_length=1, max_length=200)]
    limit: int = Field(default=5, ge=1, le=10)
    similar_to: bool = False  # the owner asked for "songs like X": answered by search, and says so


class SearchOut(MusicResult):
    query: str = ""
    similar_to: bool = False
    tracks: list[MusicTrack] = Field(default_factory=list)


class PlayIn(_In):
    query: Annotated[str, Field(min_length=1, max_length=200)] | None = None
    uri: (
        Annotated[str, Field(pattern=r"^spotify:(track|album|playlist|artist|show|episode):[A-Za-z0-9]+$")]
        | None
    ) = None
    ref: int | None = Field(default=None, ge=1, le=20)  # "the second one": 1-based, from the last search
    from_history: Literal["yesterday", "today", "last"] | None = None  # "the song I was listening to"
    target: Target | None = None  # "mac", "iphone" or a device name


class PauseIn(_In):
    target: Target | None = None


class SkipIn(_In):
    direction: Literal["next", "previous"] = "next"
    target: Target | None = None


class TransferIn(_In):
    target: Target
    play: bool = True


class RecentIn(_In):
    limit: int = Field(default=10, ge=1, le=50)
    day: Literal["today", "yesterday"] | None = None


class RecentOut(MusicResult):
    day: str | None = None
    tracks: list[MusicTrack] = Field(default_factory=list)


class PlaylistIn(_In):
    name: Annotated[str, Field(min_length=1, max_length=100)]
    description: Annotated[str, Field(max_length=300)] = ""
    public: bool = False
    track_uris: list[Annotated[str, Field(pattern=r"^spotify:track:[A-Za-z0-9]+$")]] = Field(
        default_factory=list, max_length=100
    )
    use_last_search: bool = False  # add the tracks last shown to the owner


class PlaylistOut(MusicResult):
    playlist_id: str | None = None
    name: str = ""
    url: str | None = None
    added: int = 0


# ---------------------------------------------------------------- API models


class SessionDevice(_Out):
    id: str | None = None
    name: str
    type: str = ""


class MusicSession(_Out):
    provider: Literal["spotify", "apple_music"] | None = None  # None: Spotify when connected, else device
    active_device: SessionDevice | None = None
    last_query: str | None = None
    last_track: MusicTrack | None = None
    updated_at: datetime | None = None
    updated_by: str | None = None


class MusicSessionUpdate(_In):
    provider: Literal["spotify", "apple_music"] | None = None
    active_device: SessionDevice | None = None
    last_query: Annotated[str, Field(max_length=200)] | None = None


class SpotifyStatus(_Out):
    state: Literal["not_configured", "not_connected", "connected", "needs_reauthorization"]
    detail: str


class MusicStatus(_Out):
    spotify: SpotifyStatus
    apple_music: str
    provider_in_use: Provider
    recommendations: str


class ConnectOut(_Out):
    authorize_url: str
    state: str
    expires_at: AwareDatetime
    redirect_uri: str
