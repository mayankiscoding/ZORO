"""Registers the devices package: device hub (channel + dispatcher), device tools, Home Assistant,
intents, permissions and capabilities."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

import httpx

from app.devices.api import build_router
from app.devices.capabilities import (
    device_tool_capabilities,
    home_assistant_capabilities,
    static_capabilities,
)
from app.devices.contract import PERMISSIONS
from app.devices.ha_tools import home_assistant_specs
from app.devices.homeassistant import HomeAssistantClient, HomeAssistantConfig
from app.devices.hub import Authorize, DeviceConnection, DeviceHub
from app.devices.intents import device_intents
from app.devices.tools import device_tool_specs
from app.security.devices import DeviceRegistry
from app.security.models import DeviceSession


def session_guard(devices: DeviceRegistry, session_factory: Any) -> Authorize:
    """A channel stays open only while its device and session are not revoked (the kill switch
    revokes every session, so it closes every channel at the next frame or dispatch)."""

    async def authorize(conn: DeviceConnection) -> bool:
        device = await devices.get(conn.device_id)
        if device is None or device.revoked:
            return False
        async with session_factory() as session:
            row = await session.get(DeviceSession, conn.session_id)
        return row is not None and row.device_id == conn.device_id and row.revoked_at is None

    return authorize


def install(
    reg: Any,
    *,
    env: Mapping[str, str] | None = None,
    ha_transport: httpx.AsyncBaseTransport | None = None,
) -> DeviceHub:
    """`register` with injectable environment and HTTP transport (for tests)."""
    clock = reg.service("clock")
    devices = reg.service("devices")
    hub = DeviceHub(
        clock=clock, devices=devices, authorize=session_guard(devices, reg.service("session_factory"))
    )
    reg.provide("device_hub", hub)
    reg.set_device_dispatcher(hub)

    for key, title, default in PERMISSIONS:
        reg.add_permission(key, title, default)
    for spec in device_tool_specs():  # this package is the one owner of every device contract row
        reg.add_tool(spec)
    # Approvals that no live turn stream shows (MCP calls, automation runs) reach the owner's
    # online devices as `approval_required` frames; they are also listed at /v1/approvals/pending.
    reg.service("approvals").add_announcer(hub.push_approval)

    ha = HomeAssistantClient(
        HomeAssistantConfig.from_env(env, reg.service("settings").config_dir),
        clock=clock,
        transport=ha_transport,
    )
    reg.provide("home_assistant", ha)
    for spec in home_assistant_specs(ha):
        reg.add_tool(spec)
    for intent in device_intents(lambda: ha.config):
        reg.add_intent(intent)

    reg.add_router(build_router(hub))
    reg.add_capability(lambda: device_tool_capabilities(hub.known_devices(), hub.reported()))
    reg.add_capability(lambda: home_assistant_capabilities(ha.config))
    for capability in static_capabilities():
        reg.add_capability(capability)
    reg.add_startup(hub.refresh_known)
    reg.add_shutdown(hub.close_all)
    reg.add_shutdown(ha.aclose)
    return hub


def register(reg: Any) -> None:
    install(reg)
