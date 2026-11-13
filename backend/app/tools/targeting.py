"""Which device runs a device tool.

Order: an explicit device, else (when the owner named a platform: "on my Mac") the requesting
device if it is of that platform, otherwise the most recently seen online device of that
platform; with no target at all the requesting device when it supports the tool, else the most
recently seen online device that does. A device "supports" a tool when its platform is one of the
tool's platforms and, if it reported capabilities, the tool is among them.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Literal

from app.core.types import DevicePlatform
from app.security.devices import DeviceRecord

Reason = Literal["explicit", "requester", "platform_recent", "recent"]
Problem = Literal["unknown_device", "device_revoked", "unsupported_on_device", "no_device"]
_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)


@dataclass(frozen=True)
class TargetChoice:
    device: DeviceRecord | None
    reason: Reason | None = None
    problem: Problem | None = None
    online: bool = False


def supports(device: DeviceRecord, tool_name: str, platforms: frozenset[DevicePlatform]) -> bool:
    if device.revoked or device.platform not in platforms:
        return False
    return not device.capabilities or tool_name in device.capabilities


def select_target(
    devices: Sequence[DeviceRecord],
    *,
    tool_name: str,
    platforms: frozenset[DevicePlatform],
    is_online: Callable[[str], bool],
    requesting_device_id: str | None = None,
    explicit_device_id: str | None = None,
    platform: DevicePlatform | None = None,
) -> TargetChoice:
    by_id = {d.id: d for d in devices}
    if explicit_device_id is not None:
        device = by_id.get(explicit_device_id)
        if device is None:
            return TargetChoice(None, problem="unknown_device")
        if device.revoked:
            return TargetChoice(None, problem="device_revoked")
        if not supports(device, tool_name, platforms):
            return TargetChoice(None, problem="unsupported_on_device")
        return TargetChoice(device, "explicit", online=is_online(device.id))

    wanted = platforms & {platform} if platform is not None else platforms
    if not wanted:
        return TargetChoice(None, problem="unsupported_on_device")
    requester = by_id.get(requesting_device_id) if requesting_device_id else None
    if requester is not None and supports(requester, tool_name, wanted):
        return TargetChoice(requester, "requester", online=is_online(requester.id))

    candidates = [d for d in devices if supports(d, tool_name, wanted)]
    if not candidates:
        return TargetChoice(None, problem="no_device")
    candidates.sort(key=lambda d: (is_online(d.id), d.last_seen_at or _EPOCH), reverse=True)
    best = candidates[0]
    online = is_online(best.id)
    reason: Reason = "platform_recent" if platform is not None or online else "recent"
    return TargetChoice(best, reason, online=online)
