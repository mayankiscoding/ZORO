"""Registers the music package: Spotify adapter, session context, tools, intents, routes, capabilities."""

from __future__ import annotations

import os
from collections.abc import Mapping
from typing import Any

import httpx

from app.core.types import CapabilityStatus, IntegrationLevel
from app.music.api import router
from app.music.intents import music_intents
from app.music.service import MusicService
from app.music.session import MusicSessionService
from app.music.spotify import SpotifyClient
from app.music.tools import PERMISSIONS, build_tools
from app.schemas.security import Capability


def music_capabilities(client: SpotifyClient) -> list[Capability]:
    if not client.configured:
        spotify = Capability(
            id="music.spotify",
            title="Spotify playback control",
            domain="music",
            status=CapabilityStatus.REQUIRES_CREDENTIALS,
            integration_level=IntegrationLevel.OFFICIAL_API,
            requires=["SPOTIFY_CLIENT_ID"],
            note="Create a Spotify app and set its client id. Playback control needs Premium.",
        )
    elif client.reauth_needed or not client.connected_hint:
        spotify = Capability(
            id="music.spotify",
            title="Spotify playback control",
            domain="music",
            status=CapabilityStatus.MANUAL_USER_STEP,
            integration_level=IntegrationLevel.OFFICIAL_API,
            requires=["Connect Spotify from Integrations"],
            note="Signed out or sign-in expired. A development-mode Spotify app serves at most 5 allowed users.",
        )
    else:
        spotify = Capability(
            id="music.spotify",
            title="Spotify playback control",
            domain="music",
            status=CapabilityStatus.WORKING_INTEGRATION,
            integration_level=IntegrationLevel.OFFICIAL_API,
            note="Needs Premium and an allowed Spotify account; checked by Spotify when used.",
        )
    return [
        spotify,
        Capability(
            id="music.apple_music",
            title="Apple Music playback",
            domain="music",
            status=CapabilityStatus.MANUAL_USER_STEP,
            integration_level=IntegrationLevel.DEEP_LINK_HANDOFF,
            requires=["a paired device online"],
            note="Played by the device (device.music.control); ZORO returns the plan and the device runs it.",
        ),
        Capability(
            id="music.recommendations",
            title="Spotify recommendations",
            domain="music",
            status=CapabilityStatus.UNAVAILABLE,
            integration_level=IntegrationLevel.UNAVAILABLE,
            note="Removed by Spotify for new apps (2024-11-27). 'Similar songs' is answered by search and says so.",
        ),
    ]


def install(
    reg: Any, *, env: Mapping[str, str] | None = None, http: Any = None, endpoints: Any = None
) -> MusicService:
    environment: Mapping[str, str] = env if env is not None else os.environ
    settings = reg.service("settings")
    factory = http or (lambda: httpx.AsyncClient(timeout=httpx.Timeout(15.0, connect=5.0)))
    client = SpotifyClient(
        secrets=reg.service("secrets"),
        clock=reg.service("clock"),
        http=factory,
        client_id=lambda: environment.get("SPOTIFY_CLIENT_ID", "").strip() or None,
        redirect_uri=lambda: f"{str(settings.public_base_url).rstrip('/')}/v1/music/callback",
        endpoints=endpoints,
    )
    service = MusicService(client, MusicSessionService(reg.service("session_factory"), reg.service("clock")))
    reg.provide("music", service)
    for key, title, default in PERMISSIONS:
        reg.add_permission(key, title, default)
    for spec in build_tools(service):
        reg.add_tool(spec)
    for intent in music_intents():
        reg.add_intent(intent)
    reg.add_router(router)
    reg.add_capability(lambda: music_capabilities(client))
    reg.add_startup(client.refresh_hint)
    return service


def register(reg: Any) -> None:
    install(reg)
