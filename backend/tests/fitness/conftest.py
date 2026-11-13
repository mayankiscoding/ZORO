"""Fitness tests: only the fitness plugin, a fixed clock (13 Nov 2026, noon in India)."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any

import pytest

from app.core.clock import FixedClock
from app.core.types import AgentId
from app.plugins import PluginRegistry
from app.tools.spec import ToolContext

NOW = datetime(2026, 11, 13, 6, 30, tzinfo=UTC)


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.fitness.plugin",)


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(NOW)


def make_ctx(registry: PluginRegistry, **overrides: Any) -> ToolContext:
    fields: dict[str, Any] = {
        "turn_id": "turn_fit",
        "agent": AgentId.FITNESS,
        "conversation_id": "conv_fit",
        "user_initiated": True,
    }
    fields.update(overrides)
    return registry.tool_context(**fields)


@pytest.fixture(autouse=True)
def _no_strava_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """The plugin reads STRAVA_* from the environment; tests start with none."""
    monkeypatch.delenv("STRAVA_CLIENT_ID", raising=False)
    monkeypatch.delenv("STRAVA_CLIENT_SECRET", raising=False)
