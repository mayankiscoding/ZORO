"""Kernel tests run with no plugins and a clock they control."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any

import pytest
from pydantic import BaseModel

from app.core.clock import FixedClock
from app.core.types import AgentId, DataClass, PrivacyMode, RiskLevel
from app.plugins import PluginRegistry
from app.tools.spec import ToolContext, ToolSpec


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ()


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(datetime.now(UTC).replace(microsecond=0))


class EchoIn(BaseModel):
    text: str
    count: int = 1


class EchoOut(BaseModel):
    echoed: str


async def echo_handler(ctx: ToolContext, args: EchoIn) -> EchoOut:
    return EchoOut(echoed=args.text * args.count)


def make_tool(name: str = "test.echo", **overrides: Any) -> ToolSpec:
    """A LOW-risk backend tool by default; pass ToolSpec fields to change it."""
    fields: dict[str, Any] = {
        "name": name,
        "description": "Echo the text back.",
        "input_model": EchoIn,
        "output_model": EchoOut,
        "handler": echo_handler,
        "risk": RiskLevel.LOW,
        "data_classes": frozenset({DataClass.PERSONAL}),
        "permission": None,
        "agents": frozenset({AgentId.PERSONAL_ASSISTANT}),
        "mcp_group": "test-mcp",
    }
    fields.update(overrides)
    return ToolSpec(**fields)


def make_ctx(registry: PluginRegistry, **overrides: Any) -> ToolContext:
    fields: dict[str, Any] = {
        "turn_id": "turn_test",
        "agent": AgentId.PERSONAL_ASSISTANT,
        "privacy_mode": PrivacyMode.STRICT_PRIVATE,
    }
    fields.update(overrides)
    return registry.tool_context(**fields)
