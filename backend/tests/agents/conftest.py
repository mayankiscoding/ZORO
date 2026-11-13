"""Agent tests load only the agents plugin; tools are the test-only ones from the orchestrator toolkit."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

import pytest

from app.agents.calls import Budget, RunEnv
from app.core.types import PrivacyMode
from app.plugins import PluginRegistry
from tests.fakes.gateway import FakeGateway
from tests.orchestrator.toolkit import Toolbox, install


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.agents.plugin",)


@pytest.fixture
def box(registry: PluginRegistry) -> Toolbox:
    return install(registry)


@pytest.fixture
def gateway(registry: PluginRegistry) -> FakeGateway:
    fake = FakeGateway()
    registry.provide("gateway", fake)
    return fake


class Recorder:
    def __init__(self) -> None:
        self.events: list[Any] = []

    async def __call__(self, event: Any) -> None:
        self.events.append(event)

    @property
    def kinds(self) -> list[str]:
        return [event.type for event in self.events]


@pytest.fixture
def recorder() -> Recorder:
    return Recorder()


def make_env(recorder: Recorder, **kw: Any) -> RunEnv:
    fields: dict[str, Any] = {
        "turn_id": "turn_agents",
        "conversation_id": "conv_agents",
        "privacy_mode": PrivacyMode.CLOUD_INTELLIGENCE,
        "user_initiated": True,
        "emit": recorder,
        "budget": Budget(),
    }
    fields.update(kw)
    return RunEnv(**fields)
