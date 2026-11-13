"""Capability entries: per-tool status from what devices report, iOS restrictions, manual steps."""

from __future__ import annotations

import json

import httpx

from app.core.types import CapabilityStatus, DevicePlatform
from app.devices.capabilities import device_tool_capabilities
from app.devices.contract import ROWS
from app.devices.hub import KnownDevice
from app.plugins import PluginRegistry
from tests.conftest import PairedDevice
from tests.devices.conftest import FakeChannel, hub_of, signed_in_conn

S = CapabilityStatus


def by_id(known: list[KnownDevice]) -> dict[str, S]:
    return {c.id: c.status for c in device_tool_capabilities(known)}


def test_one_entry_per_tool_and_nothing_works_without_a_device() -> None:
    caps = device_tool_capabilities([])
    assert {c.id for c in caps} == {row.name for row in ROWS}
    assert {c.status for c in caps} == {S.UNAVAILABLE}
    assert all("no iPhone is paired" in c.note or "no Mac is paired" in c.note for c in caps)


def test_status_follows_reported_capabilities() -> None:
    phone = KnownDevice(
        "p", DevicePlatform.IOS, ("ios.alarm.create", "device.shortcut.run", "device.health.query")
    )
    mac = KnownDevice("m", DevicePlatform.MACOS, ("device.shortcut.run", "mac.file.search"))
    status = by_id([phone, mac])
    assert status["ios.alarm.create"] is S.WORKING_NATIVE
    assert status["ios.timer.start"] is S.UNAVAILABLE  # the app did not report it (e.g. iOS < 26)
    assert status["device.shortcut.run"] is S.WORKING_NATIVE  # Mac runs it; the iPhone hands off
    assert status["device.health.query"] is S.WORKING_NATIVE
    assert status["ios.message.compose"] is S.UNAVAILABLE
    health = next(c for c in device_tool_capabilities([phone, mac]) if c.id == "device.health.query")
    assert "Mac: not supported" in health.note
    unknown = by_id([KnownDevice("p2", DevicePlatform.IOS, ())])
    assert unknown["device.whatsapp.compose"] is S.MANUAL_USER_STEP
    assert unknown["ios.message.compose"] is S.MANUAL_USER_STEP


async def test_registry_has_restricted_and_manual_entries(
    registry: PluginRegistry, paired_device: PairedDevice, client: httpx.AsyncClient
) -> None:
    caps = {c.id: c for c in registry.capabilities.all(domain="devices")}
    restricted = {k for k, c in caps.items() if c.status is S.RESTRICTED_BY_IOS}
    assert restricted == {
        "devices.restricted.wake_word", "devices.restricted.background_listening",
        "devices.restricted.read_other_apps", "devices.restricted.silent_send",
        "devices.restricted.drive_other_apps", "devices.restricted.apple_notes_direct",
    }  # fmt: skip
    assert caps["devices.setup.action_button"].status is S.MANUAL_USER_STEP
    assert caps["devices.notes.via_shortcut"].status is S.MANUAL_USER_STEP
    home = {c.id: c.status for c in registry.capabilities.all(domain="home")}
    assert home["homeassistant.call_service"] in {S.REQUIRES_CREDENTIALS, S.WORKING_INTEGRATION}

    # A hello frame makes the tools it lists working on that platform.
    hub = hub_of(registry)
    conn = await signed_in_conn(registry, paired_device.token, FakeChannel())
    await hub.connect(conn)
    await hub.handle_text(conn, json.dumps({"type": "hello", "capabilities": ["ios.timer.start"]}))
    response = await client.get(
        "/v1/capabilities", params={"domain": "devices"}, headers=paired_device.headers
    )
    listed = {c["id"]: c["status"] for c in response.json()["items"]}
    assert listed["ios.timer.start"] == "working_native"
    assert listed["ios.alarm.create"] == "unavailable"
