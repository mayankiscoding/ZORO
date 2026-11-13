"""Home Assistant adapter with httpx.MockTransport (never the network)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import httpx
import pytest

from app.core.clock import FixedClock
from app.core.errors import BadRequest, Forbidden, NotFound, Unavailable, ZoroError
from app.core.settings import Settings
from app.core.types import AgentId, CapabilityStatus
from app.devices.capabilities import home_assistant_capabilities
from app.devices.ha_tools import CallServiceOut, GetStateOut
from app.devices.homeassistant import HomeAssistantClient, HomeAssistantConfig
from app.devices.plugin import install
from app.plugins import build_kernel
from app.tools.outcome import Completed, Failed, NeedsApproval
from tests.devices.conftest import NOW

ENV = {
    "HOME_ASSISTANT_URL": "http://ha.local:8123/",
    "HOME_ASSISTANT_TOKEN": "test-long-lived-token",
    "HOME_ASSISTANT_ENTITIES": "light.bedroom=Bedroom|बेडरूम, switch.fan, lock.front_door_BAD!, sensor.temp=Temperature",
}
STATE = {
    "entity_id": "sensor.temp",
    "state": "24.5",
    "attributes": {"unit_of_measurement": "°C", "friendly_name": "Temperature"},
    "last_changed": "2026-11-13T04:00:00+00:00",
}


class Recorder:
    def __init__(self, status: int = 200, body: Any = None, raise_exc: Exception | None = None) -> None:
        self.requests: list[httpx.Request] = []
        self.status, self.body, self.raise_exc = status, body, raise_exc

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.raise_exc is not None:
            raise self.raise_exc
        if request.method == "GET":
            return httpx.Response(self.status, json=self.body if self.body is not None else STATE)
        default = [
            {"entity_id": "light.bedroom", "state": "off"},
            {"entity_id": "light.other", "state": "on"},
        ]
        return httpx.Response(self.status, json=self.body if self.body is not None else default)


def client(recorder: Recorder, env: dict[str, str] | None = None) -> HomeAssistantClient:
    config = HomeAssistantConfig.from_env(ENV if env is None else env)
    return HomeAssistantClient(config, clock=FixedClock(NOW), transport=httpx.MockTransport(recorder))


def test_config_from_env_and_yaml(tmp_path: Path) -> None:
    config = HomeAssistantConfig.from_env(ENV)
    assert config.enabled and config.url == "http://ha.local:8123"
    assert [e.entity_id for e in config.entities] == ["light.bedroom", "sensor.temp", "switch.fan"]
    assert config.entity("light.bedroom").aliases == ("बेडरूम",)  # type: ignore[union-attr]
    assert config.entity("switch.fan").name == "Fan"  # type: ignore[union-attr]
    assert "test-long-lived-token" not in repr(config)
    (tmp_path / "home_assistant.yaml").write_text(
        "entities:\n  - id: light.porch\n    name: Porch\n    aliases: [bahar]\n  - id: not valid\n",
        encoding="utf-8",
    )
    with_yaml = HomeAssistantConfig.from_env({}, tmp_path)
    assert not with_yaml.enabled and [e.entity_id for e in with_yaml.entities] == ["light.porch"]
    assert not HomeAssistantConfig.from_env(
        {"HOME_ASSISTANT_URL": "ftp://x", "HOME_ASSISTANT_TOKEN": "t"}
    ).enabled


async def test_disabled_when_credentials_missing() -> None:
    recorder = Recorder()
    ha = client(recorder, env={"HOME_ASSISTANT_ENTITIES": "light.bedroom"})
    with pytest.raises(Unavailable) as error:
        await ha.call_service("light", "turn_on", ["light.bedroom"], {})
    assert error.value.error_code == "home_assistant_not_configured"
    with pytest.raises(Unavailable):
        await ha.get_state("light.bedroom")
    assert recorder.requests == []
    caps = home_assistant_capabilities(ha.config)
    assert {c.status for c in caps} == {CapabilityStatus.REQUIRES_CREDENTIALS}


async def test_call_service_sends_bearer_and_body() -> None:
    recorder = Recorder()
    ha = client(recorder)
    changed = await ha.call_service("light", "turn_off", ["light.bedroom"], {})
    request = recorder.requests[0]
    assert request.method == "POST" and request.url.path == "/api/services/light/turn_off"
    assert request.headers["authorization"] == "Bearer test-long-lived-token"
    assert json.loads(request.content) == {"entity_id": ["light.bedroom"]}
    assert changed[0]["state"] == "off"


async def test_refusals_happen_before_any_request() -> None:
    recorder = Recorder()
    ha = client(recorder)
    with pytest.raises(Forbidden) as not_listed:
        await ha.call_service("light", "turn_on", ["light.kitchen"], {})
    assert not_listed.value.error_code == "entity_not_allowlisted"
    with pytest.raises(Forbidden) as service:
        await ha.call_service("lock", "unlock", ["lock.front_door"], {})
    assert service.value.error_code == "service_not_allowed"
    with pytest.raises(BadRequest) as mismatch:
        await ha.call_service("light", "turn_on", ["switch.fan"], {})
    assert mismatch.value.error_code == "entity_domain_mismatch"
    with pytest.raises(BadRequest):
        await ha.call_service("light", "turn_on", [], {})
    with pytest.raises(Forbidden):
        await ha.get_state("sensor.secret")
    assert recorder.requests == []


@pytest.mark.parametrize(
    ("recorder", "error", "code"),
    [
        (Recorder(status=401, body={"message": "no"}), ZoroError, "home_assistant_unauthorized"),
        (Recorder(status=404, body={}), NotFound, "home_assistant_not_found"),
        (Recorder(status=400, body={}), BadRequest, "home_assistant_rejected"),
        (Recorder(status=500, body={}), ZoroError, "home_assistant_error"),
        (Recorder(raise_exc=httpx.ConnectError("down")), Unavailable, "home_assistant_unreachable"),
        (Recorder(raise_exc=httpx.ReadTimeout("slow")), Unavailable, "home_assistant_timeout"),
        (Recorder(body={"no_state": True}), ZoroError, "home_assistant_bad_response"),
    ],
)
async def test_http_failures_are_typed(recorder: Recorder, error: type[Exception], code: str) -> None:
    ha = client(recorder)
    with pytest.raises(error) as raised:
        await ha.get_state("sensor.temp")
    assert getattr(raised.value, "error_code", None) == code


async def test_tools_through_the_executor(settings: Settings) -> None:
    recorder = Recorder()
    reg = build_kernel(settings, clock=FixedClock(NOW))
    install(reg, env=ENV, ha_transport=httpx.MockTransport(recorder))
    await reg.service("database").init(packages=[])
    executor = reg.service("tool_executor")
    try:
        ctx = reg.tool_context(
            turn_id="t1", agent=AgentId.DEVICE_CONTROL, user_initiated=True, lang="hinglish"
        )
        state = await executor.execute(
            ctx, "homeassistant.get_state", {"entity_id": "sensor.temp"}, call_id="c1"
        )
        assert isinstance(state, Completed) and isinstance(state.result, GetStateOut)
        assert (
            state.result.state == "24.5"
            and state.result.unit == "°C"
            and state.result.source == "home_assistant"
        )
        assert state.summary == "Temperature abhi 24.5 °C hai."

        args = {"domain": "light", "service": "turn_off", "entity_ids": ["light.bedroom"]}
        done = await executor.execute(ctx, "homeassistant.call_service", args, call_id="c2")
        assert isinstance(done, Completed) and isinstance(done.result, CallServiceOut)
        assert [c.model_dump() for c in done.result.changed] == [
            {"entity_id": "light.bedroom", "state": "off"}
        ]
        assert done.summary == "Bedroom band kar diya."
        again = await executor.execute(ctx, "homeassistant.call_service", args, call_id="c2")
        assert isinstance(again, Completed) and sum(r.method == "POST" for r in recorder.requests) == 1

        bad = await executor.execute(
            ctx, "homeassistant.call_service", {**args, "entity_ids": ["light.kitchen"]}, call_id="c3"
        )
        assert isinstance(bad, Failed) and bad.error == "entity_not_allowlisted"

        unasked = reg.tool_context(turn_id="t2", agent=AgentId.DEVICE_CONTROL, user_initiated=False)
        pending = await executor.execute(unasked, "homeassistant.call_service", args, call_id="c4")
        assert isinstance(pending, NeedsApproval) and "light.bedroom" in pending.request.title
        caps = {c.id: c for c in reg.capabilities.all(domain="home")}
        assert caps["homeassistant.call_service"].status is CapabilityStatus.WORKING_INTEGRATION
    finally:
        await reg.run_shutdown()
        await reg.service("database").dispose()
