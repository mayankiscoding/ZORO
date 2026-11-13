"""Devices tests: only the devices plugin, and a clock the tests control."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest

from app.core.clock import FixedClock
from app.core.types import DevicePlatform, RiskLevel
from app.devices.hub import DeviceConnection, DeviceHub
from app.schemas.turns import DeviceActionRequest, DeviceActionResult

# Friday 13 November 2026, 10:00 in Asia/Kolkata.
NOW = datetime(2026, 11, 13, 4, 30, tzinfo=UTC)


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.devices.plugin",)


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(NOW)


@dataclass
class FakeChannel:
    """Stands in for a WebSocket: records frames sent and the close code."""

    sent: list[dict[str, Any]] = field(default_factory=list)
    closed: tuple[int, str] | None = None
    fail_send: bool = False

    async def send(self, frame: dict[str, Any]) -> None:
        if self.fail_send:
            raise RuntimeError("socket gone")
        self.sent.append(frame)

    async def close(self, code: int, reason: str) -> None:
        self.closed = (code, reason)


def make_conn(
    channel: FakeChannel,
    device_id: str,
    now: datetime,
    *,
    platform: DevicePlatform = DevicePlatform.IOS,
    session_id: str = "ses_test",
) -> DeviceConnection:
    return DeviceConnection(
        device_id=device_id,
        session_id=session_id,
        platform=platform,
        name="Test device",
        send=channel.send,
        close=channel.close,
        connected_at=now,
        last_frame_at=now,
    )


def make_request(
    action_id: str, device_id: str, now: datetime, *, tool: str = "ios.timer.start", seconds: int = 60
) -> DeviceActionRequest:
    return DeviceActionRequest(
        action_id=action_id,
        target_device_id=device_id,
        tool=tool,
        args={"seconds": 60},
        risk=RiskLevel.MEDIUM,
        expires_at=now + timedelta(seconds=seconds),
    )


def make_result(action_id: str, now: datetime, **result: Any) -> DeviceActionResult:
    return DeviceActionResult(
        action_id=action_id, ok=True, result=result or {"timer_id": "t1"}, executed_at=now
    )


async def wait_for_frames(channel: FakeChannel, count: int = 1) -> None:
    import asyncio

    for _ in range(200):
        if len(channel.sent) >= count:
            return
        await asyncio.sleep(0.005)
    raise AssertionError(f"expected {count} frame(s), got {len(channel.sent)}")


async def signed_in_conn(registry: Any, token: str, channel: FakeChannel) -> DeviceConnection:
    """A connection carrying the real session of a paired device (as the WebSocket route builds it)."""
    authed = await registry.service("sessions").authenticate(token)
    now = registry.service("clock").now()
    return make_conn(channel, authed.device_id, now, platform=authed.platform, session_id=authed.session_id)


def hub_of(registry: Any) -> DeviceHub:
    hub: DeviceHub = registry.service("device_hub")
    return hub
