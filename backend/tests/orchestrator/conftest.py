"""Orchestrator tests: only the agents and orchestrator plugins are loaded; domain tools are the
test-only ones in `toolkit.py`, and the model gateway is the scripted `FakeGateway`."""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Sequence
from datetime import UTC, datetime
from typing import Any

import pytest

from app.core.clock import FixedClock
from app.core.types import DevicePlatform, PrivacyMode
from app.plugins import PluginRegistry
from app.schemas.turns import ClientContext, TurnInput, TurnRequest
from app.security.sessions import AuthedDevice
from tests.conftest import PairedDevice
from tests.fakes.gateway import FakeGateway
from tests.orchestrator.toolkit import Toolbox, install


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.agents.plugin", "app.orchestrator.plugin")


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(datetime.now(UTC).replace(microsecond=0))


@pytest.fixture
def box(registry: PluginRegistry) -> Toolbox:
    return install(registry)


@pytest.fixture
def gateway(registry: PluginRegistry) -> FakeGateway:
    fake = FakeGateway()
    registry.provide("gateway", fake)
    return fake


@pytest.fixture
async def authed(registry: PluginRegistry, paired_device: PairedDevice) -> AuthedDevice:
    device: AuthedDevice = await registry.service("sessions").authenticate(paired_device.token)
    return device


def turn_request(text: str, **kw: Any) -> TurnRequest:
    return TurnRequest(
        conversation_id=kw.get("conversation_id"),
        input=TurnInput(
            text=text, modality=kw.get("modality", "text"), language_hint=kw.get("language_hint")
        ),
        client=ClientContext(platform=DevicePlatform.IOS, app_state=kw.get("app_state", {})),
        privacy_mode=kw.get("privacy_mode"),
    )


Ask = Callable[..., Awaitable[list[Any]]]


@pytest.fixture
def ask(registry: PluginRegistry, authed: AuthedDevice) -> Ask:
    """`await ask("text", conversation_id=...)` runs a turn and returns its events."""

    async def _ask(text: str, **kw: Any) -> list[Any]:
        stream = await registry.service("turn_service").start(
            turn_request(text, **kw), kw.get("device", authed)
        )
        return [event async for event in stream]

    return _ask


def of(events: list[Any], kind: str) -> list[Any]:
    return [event for event in events if event.type == kind]


def text_of(events: list[Any]) -> str:
    return "".join(event.text for event in of(events, "text_delta"))


async def cloud_mode(registry: PluginRegistry) -> None:
    await registry.service("privacy_state").set_mode(PrivacyMode.CLOUD_INTELLIGENCE)
