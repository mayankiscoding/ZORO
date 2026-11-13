"""Memory tests load only the memory plugin and control the clock."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any

import pytest

from app.core.clock import FixedClock
from app.core.types import AgentId, PrivacyMode
from app.memory.service import MemoryService
from app.plugins import PluginRegistry
from app.tools.spec import ToolContext
from tests.fakes.gateway import FakeGateway


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.memory.plugin",)


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(datetime.now(UTC).replace(microsecond=0))


@pytest.fixture
def memory(registry: PluginRegistry) -> MemoryService:
    service: MemoryService = registry.service("memory")
    return service


@pytest.fixture
def gateway(registry: PluginRegistry) -> FakeGateway:
    """A scripted gateway provided under the name the real one uses."""
    gw = FakeGateway()
    registry.provide("gateway", gw)
    return gw


def make_ctx(registry: PluginRegistry, **overrides: Any) -> ToolContext:
    fields: dict[str, Any] = {
        "turn_id": "turn_test",
        "agent": AgentId.MEMORY,
        "conversation_id": "conv_1",
        "privacy_mode": PrivacyMode.STRICT_PRIVATE,
        "user_initiated": True,
    }
    fields.update(overrides)
    has_gateway = "gateway" in fields
    gateway = fields.pop("gateway", None)
    ctx = registry.tool_context(**fields)
    if has_gateway:
        ctx.gateway = gateway
    return ctx
