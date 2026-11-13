"""The kernel executor runs device tools on another device through the hub."""

from __future__ import annotations

import asyncio

from app.core.types import AgentId, DevicePlatform
from app.plugins import PluginRegistry
from app.tools.outcome import Completed, Denied, Failed, NeedsDeviceAction
from tests.conftest import PairDevice
from tests.devices.conftest import FakeChannel, hub_of, make_result, signed_in_conn, wait_for_frames


async def test_mac_tool_from_iphone_runs_on_connected_mac(
    registry: PluginRegistry, pair_device: PairDevice
) -> None:
    phone = await pair_device(name="Phone")
    mac = await pair_device(name="Mac", platform=DevicePlatform.MACOS)
    hub, executor = hub_of(registry), registry.service("tool_executor")
    ctx = registry.tool_context(
        turn_id="t1", agent=AgentId.DEVICE_CONTROL, device_id=phone.device_id, user_initiated=True
    )

    denied = await executor.execute(ctx, "mac.file.search", {"query": "budget"}, call_id="c0")
    assert isinstance(denied, Denied) and denied.reason == "permission_not_granted:devices.mac_files"
    await registry.service("permissions").set("devices.mac_files", True)

    offline = await executor.execute(ctx, "mac.file.search", {"query": "budget"}, call_id="c1")
    assert isinstance(offline, Failed) and offline.error == "device_offline"

    channel = FakeChannel()
    conn = await signed_in_conn(registry, mac.token, channel)
    await hub.connect(conn)
    task = asyncio.create_task(executor.execute(ctx, "mac.file.search", {"query": "budget"}, call_id="c2"))
    await wait_for_frames(channel)
    action = channel.sent[0]["action"]
    assert action["tool"] == "mac.file.search" and action["target_device_id"] == mac.device_id
    files = {"files": [{"path_ref": "docs:Budget.xlsx", "name": "Budget.xlsx"}]}
    await hub.submit_result(
        mac.device_id, make_result(action["action_id"], registry.service("clock").now(), **files)
    )
    outcome = await task
    assert isinstance(outcome, Completed) and outcome.summary == "Found Budget.xlsx."
    assert outcome.untrusted and outcome.card is not None and outcome.card.kind == "files"


async def test_requesting_device_gets_needs_device_action(
    registry: PluginRegistry, pair_device: PairDevice
) -> None:
    phone = await pair_device(name="Phone")
    executor = registry.service("tool_executor")
    ctx = registry.tool_context(
        turn_id="t2", agent=AgentId.DEVICE_CONTROL, device_id=phone.device_id, user_initiated=True, lang="hi"
    )
    outcome = await executor.execute(
        ctx, "ios.timer.start", {"seconds": 600, "_target_platform": "ios"}, call_id="c3"
    )
    assert isinstance(outcome, NeedsDeviceAction) and outcome.request.args == {"seconds": 600, "label": None}
    resumed = await executor.resume_with_device_result(
        registry.tool_context(
            turn_id="t2", agent=AgentId.DEVICE_CONTROL, device_id=phone.device_id, lang="hi"
        ),
        "c3",
        make_result(outcome.request.action_id, registry.service("clock").now(), timer_id="t1"),
    )
    assert isinstance(resumed, Completed) and resumed.summary == "टाइमर शुरू हो गया।"


async def test_agent_outside_allowlist_is_denied(registry: PluginRegistry) -> None:
    ctx = registry.tool_context(turn_id="t3", agent=AgentId.SHOPPING)
    outcome = await registry.service("tool_executor").execute(ctx, "device.health.query", {}, call_id="c4")
    assert isinstance(outcome, Denied) and outcome.reason == "agent_not_allowed"
