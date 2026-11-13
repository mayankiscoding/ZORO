"""Vision tests: only the vision plugin, a fixed clock (Friday 13 Nov 2026, noon in India)."""

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
    return ("app.vision.plugin",)


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(NOW)


def make_ctx(registry: PluginRegistry, **overrides: Any) -> ToolContext:
    fields: dict[str, Any] = {
        "turn_id": "turn_vis",
        "agent": AgentId.VISION,
        "conversation_id": "conv_vis",
        "user_initiated": True,
    }
    fields.update(overrides)
    return registry.tool_context(**fields)
