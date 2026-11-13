"""DeviceHub: hello, dispatch, results, timeouts, expiry, duplicates, presence, revocation."""

from __future__ import annotations

import asyncio
import json
from datetime import timedelta

import pytest

from app.core.clock import FixedClock
from app.devices.hub import CLOSE_POLICY, CLOSE_REPLACED, MAX_BAD_FRAMES, DeviceHub
from app.plugins import PluginRegistry
from app.schemas.turns import ApprovalRequest
from app.tools.dispatcher import DeviceDispatcher, DeviceOffline
from tests.conftest import PairDevice
from tests.devices.conftest import (
    FakeChannel,
    hub_of,
    make_conn,
    make_request,
    make_result,
    signed_in_conn,
    wait_for_frames,
)


def test_hub_is_the_kernel_dispatcher(registry: PluginRegistry) -> None:
    hub = hub_of(registry)
    assert isinstance(hub, DeviceDispatcher)
    assert registry.device_dispatcher is hub


async def test_hello_records_and_persists_capabilities(
    registry: PluginRegistry, pair_device: PairDevice
) -> None:
    device = await pair_device()
    hub = hub_of(registry)
    channel = FakeChannel()
    conn = await signed_in_conn(registry, device.token, channel)
    await hub.connect(conn)
    hello = {"type": "hello", "capabilities": ["ios.timer.start", "ios.alarm.create", 7, "x" * 200]}
    assert await hub.handle_text(conn, json.dumps(hello))
    assert hub.capabilities(device.device_id) == ("ios.alarm.create", "ios.timer.start")
    record = await registry.service("devices").get(device.device_id)
    assert record.capabilities == ("ios.alarm.create", "ios.timer.start")
    assert hub.is_online(device.device_id)
    assert [p.device_id for p in hub.presence()] == [device.device_id]


async def test_dispatch_sends_frame_and_returns_matching_result(
    registry: PluginRegistry, pair_device: PairDevice
) -> None:
    device = await pair_device()
    hub, now = hub_of(registry), registry.service("clock").now()
    channel = FakeChannel()
    conn = await signed_in_conn(registry, device.token, channel)
    await hub.connect(conn)

    task = asyncio.create_task(
        hub.dispatch(device.device_id, make_request("act_1", device.device_id, now), 5)
    )
    await wait_for_frames(channel)
    frame = channel.sent[0]
    assert frame["type"] == "device_action" and frame["action"]["action_id"] == "act_1"
    assert hub.pending_actions(device.device_id)[0].action_id == "act_1"

    reply = {"type": "device_action_result", "result": make_result("act_1", now).model_dump(mode="json")}
    assert await hub.handle_text(conn, json.dumps(reply))
    result = await task
    assert result.ok and result.result == {"timer_id": "t1"}
    assert hub.pending_actions() == []

    # Same result again: never applied twice. Re-dispatching the finished action returns it unchanged.
    assert await hub.submit_result(device.device_id, make_result("act_1", now)) == "duplicate"
    again = await hub.dispatch(device.device_id, make_request("act_1", device.device_id, now), 5)
    assert again == result and len(channel.sent) == 1


async def test_result_from_another_device_is_ignored(registry: PluginRegistry) -> None:
    hub, now = hub_of(registry), registry.service("clock").now()
    hub_plain = DeviceHub(clock=registry.service("clock"))
    channel = FakeChannel()
    await hub_plain.connect(make_conn(channel, "dev_a", now))
    task = asyncio.create_task(hub_plain.dispatch("dev_a", make_request("act_2", "dev_a", now), 5))
    await wait_for_frames(channel)
    assert await hub_plain.submit_result("dev_b", make_result("act_2", now)) == "wrong_device"
    assert await hub_plain.submit_result("dev_a", make_result("act_2", now)) == "accepted"
    assert (await task).action_id == "act_2"
    assert await hub.submit_result("dev_a", make_result("act_unknown", now)) == "unknown"


async def test_timeout_raises_offline_and_late_result_is_expired(clock: FixedClock) -> None:
    hub = DeviceHub(clock=clock)
    channel = FakeChannel()
    await hub.connect(make_conn(channel, "dev_a", clock.now()))
    with pytest.raises(DeviceOffline):
        await hub.dispatch("dev_a", make_request("act_3", "dev_a", clock.now()), 0.05)
    assert await hub.submit_result("dev_a", make_result("act_3", clock.now())) == "expired"
    with pytest.raises(DeviceOffline):  # an expired action is never sent again
        await hub.dispatch("dev_a", make_request("act_3", "dev_a", clock.now()), 1)
    assert len(channel.sent) == 1


async def test_result_after_expiry_is_refused(clock: FixedClock) -> None:
    hub = DeviceHub(clock=clock)
    channel = FakeChannel()
    await hub.connect(make_conn(channel, "dev_a", clock.now()))
    task = asyncio.create_task(
        hub.dispatch("dev_a", make_request("act_4", "dev_a", clock.now(), seconds=30), 5)
    )
    await wait_for_frames(channel)
    clock.advance(31)
    assert await hub.submit_result("dev_a", make_result("act_4", clock.now())) == "expired"
    with pytest.raises(DeviceOffline):
        await task
    assert await hub.submit_result("dev_a", make_result("act_4", clock.now())) == "expired"


async def test_offline_stale_and_already_expired(clock: FixedClock) -> None:
    hub = DeviceHub(clock=clock, stale_after_s=120)
    with pytest.raises(DeviceOffline):
        await hub.dispatch("dev_missing", make_request("act_5", "dev_missing", clock.now()), 1)
    channel = FakeChannel()
    conn = make_conn(channel, "dev_a", clock.now())
    await hub.connect(conn)
    with pytest.raises(DeviceOffline):  # expires_at already passed
        await hub.dispatch("dev_a", make_request("act_6", "dev_a", clock.now(), seconds=-1), 1)
    with pytest.raises(DeviceOffline):  # aimed at another device
        await hub.dispatch("dev_a", make_request("act_7", "dev_b", clock.now()), 1)
    clock.advance(121)
    assert not hub.is_online("dev_a")
    with pytest.raises(DeviceOffline):
        await hub.dispatch("dev_a", make_request("act_8", "dev_a", clock.now()), 1)
    assert await hub.handle_text(conn, '{"type": "ping"}')
    assert hub.is_online("dev_a")
    assert channel.sent == []


async def test_send_failure_is_offline_and_detaches(clock: FixedClock) -> None:
    hub = DeviceHub(clock=clock)
    await hub.connect(make_conn(FakeChannel(fail_send=True), "dev_a", clock.now()))
    with pytest.raises(DeviceOffline):
        await hub.dispatch("dev_a", make_request("act_9", "dev_a", clock.now()), 1)
    assert not hub.is_online("dev_a")


async def test_disconnect_keeps_pending_for_rest_fallback(clock: FixedClock) -> None:
    hub = DeviceHub(clock=clock)
    channel = FakeChannel()
    conn = make_conn(channel, "dev_a", clock.now())
    await hub.connect(conn)
    task = asyncio.create_task(hub.dispatch("dev_a", make_request("act_10", "dev_a", clock.now()), 5))
    await wait_for_frames(channel)
    await hub.disconnect(conn)
    assert not hub.is_online("dev_a")
    assert await hub.submit_result("dev_a", make_result("act_10", clock.now())) == "accepted"
    assert (await task).ok


async def test_new_channel_replaces_old(clock: FixedClock) -> None:
    hub = DeviceHub(clock=clock)
    first, second = FakeChannel(), FakeChannel()
    old = make_conn(first, "dev_a", clock.now())
    await hub.connect(old)
    await hub.connect(make_conn(second, "dev_a", clock.now()))
    assert first.closed is not None and first.closed[0] == CLOSE_REPLACED
    await hub.disconnect(old)  # the old socket's cleanup must not detach the new one
    assert hub.is_online("dev_a")


async def test_bad_frames_are_ignored_then_close(clock: FixedClock) -> None:
    hub = DeviceHub(clock=clock)
    channel = FakeChannel()
    conn = make_conn(channel, "dev_a", clock.now())
    await hub.connect(conn)
    assert await hub.handle_text(conn, '{"type": "device_action_result", "result": {"ok": "maybe"}}')
    for _ in range(MAX_BAD_FRAMES - 2):
        assert await hub.handle_text(conn, "not json")
    assert not await hub.handle_text(conn, "[]")
    assert channel.closed is not None and channel.closed[0] == CLOSE_POLICY
    assert not hub.is_online("dev_a")


async def test_revoked_session_closes_channel_and_blocks_dispatch(clock: FixedClock) -> None:
    allowed = {"ok": True}

    async def authorize(_conn: object) -> bool:
        return allowed["ok"]

    hub = DeviceHub(clock=clock, authorize=authorize)
    channel = FakeChannel()
    conn = make_conn(channel, "dev_a", clock.now())
    await hub.connect(conn)
    allowed["ok"] = False
    with pytest.raises(DeviceOffline):
        await hub.dispatch("dev_a", make_request("act_11", "dev_a", clock.now()), 1)
    assert channel.closed == (CLOSE_POLICY, "session_revoked")
    await hub.connect(conn)
    assert not await hub.handle_text(conn, '{"type": "ping"}')


async def test_push_approval_and_close_all(clock: FixedClock) -> None:
    hub = DeviceHub(clock=clock)
    channel = FakeChannel()
    await hub.connect(make_conn(channel, "dev_a", clock.now()))
    approval = ApprovalRequest(
        approval_id="apr_1", tool="device.whatsapp.compose", risk="high", level="confirm", title="t",
        summary="s", action_digest="0" * 64, expires_at=clock.now() + timedelta(minutes=5),
    )  # fmt: skip
    assert await hub.push_approval(approval) == ["dev_a"]
    assert channel.sent[-1]["type"] == "approval_required"
    assert await hub.push_approval(approval, ["dev_offline"]) == []

    task = asyncio.create_task(hub.dispatch("dev_a", make_request("act_12", "dev_a", clock.now()), 5))
    await wait_for_frames(channel, 2)
    await hub.close_all()
    with pytest.raises(DeviceOffline):
        await task
    assert channel.closed is not None and channel.closed[0] == 1001
