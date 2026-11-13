from __future__ import annotations

import json
from collections.abc import Callable, Iterator, Sequence
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest

from app.core.clock import FixedClock
from app.core.types import AgentId
from app.music.service import MusicService
from app.plugins import PluginRegistry
from app.tools.spec import ToolContext
from tests.music import harness

Route = Callable[[httpx.Request], httpx.Response]
API = "api.spotify.com"
TOKEN = "accounts.spotify.com/api/token"


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("tests.music.harness",)


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(datetime(2026, 11, 13, 10, 0, tzinfo=UTC))


@pytest.fixture(autouse=True)
def reset() -> Iterator[None]:
    harness.ENV.clear()
    harness.SEEN.clear()
    harness.ROUTES.clear()
    yield
    harness.ENV.clear()


@pytest.fixture
def env() -> dict[str, str]:
    return harness.ENV


@pytest.fixture
def seen() -> list[httpx.Request]:
    return harness.SEEN


@pytest.fixture
def route() -> Callable[[str, str, Route], None]:
    def _add(method: str, where: str, fn: Route) -> None:
        harness.ROUTES[(method, where)] = fn

    return _add


@pytest.fixture
def music(registry: PluginRegistry) -> MusicService:
    service: MusicService = registry.service("music")
    return service


@pytest.fixture
async def connected(registry: PluginRegistry, clock: FixedClock, env: dict[str, str]) -> None:
    """Spotify configured and signed in with a token valid for an hour."""
    env["SPOTIFY_CLIENT_ID"] = "client-123"
    record = {
        "access_token": "AT-1",
        "refresh_token": "RT-1",
        "expires_at": (clock.now() + timedelta(hours=1)).isoformat(),
        "scope": "",
    }
    await registry.service("secrets").put("spotify", json.dumps(record))
    await registry.service("music").spotify.refresh_hint()


def ctx_for(registry: PluginRegistry, **overrides: Any) -> ToolContext:
    fields: dict[str, Any] = {
        "turn_id": "turn_music",
        "agent": AgentId.MUSIC,
        "conversation_id": "conv_music",
        "user_initiated": True,
    }
    fields.update(overrides)
    return registry.tool_context(**fields)


def track(n: int, name: str = "Song") -> dict[str, Any]:
    return {
        "uri": f"spotify:track:T{n}",
        "name": f"{name} {n}",
        "artists": [{"name": f"Artist {n}"}],
        "album": {"name": f"Album {n}"},
    }


def device(did: str, name: str, kind: str, active: bool = False) -> dict[str, Any]:
    return {"id": did, "name": name, "type": kind, "is_active": active, "volume_percent": 40}
