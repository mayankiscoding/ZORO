"""Capability entries for device tools, iOS restrictions, manual steps and Home Assistant.

Device tool status is computed on every read from what paired devices last reported, so a tool is
only "working_native" when an app of the right platform has said it can run it.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence

from app.core.types import CapabilityStatus, DevicePlatform, IntegrationLevel
from app.devices.contract import RESTRICTED_BY_IOS, ROWS, DeviceToolRow
from app.devices.homeassistant import ENV_TOKEN, ENV_URL, HomeAssistantConfig
from app.devices.hub import KnownDevice
from app.schemas.security import Capability

S = CapabilityStatus
_LABEL = {DevicePlatform.IOS: "iPhone", DevicePlatform.MACOS: "Mac"}
_RANK = (S.WORKING_NATIVE, S.MANUAL_USER_STEP, S.UNAVAILABLE)


Reported = Mapping[tuple[str, str], tuple[S, str]]  # (device id, tool) -> (status, reason)


def _platform_status(
    row: DeviceToolRow, platform: DevicePlatform, known: Sequence[KnownDevice], reported: Reported
) -> tuple[S, str]:
    label = _LABEL[platform]
    base = row.status.get(platform, S.UNAVAILABLE)
    extra = row.platform_notes.get(platform, "")
    if base is S.UNAVAILABLE:
        return base, f"{label}: not supported. {extra}".strip()
    devices = [d for d in known if d.platform is platform]
    if not devices:
        return S.UNAVAILABLE, f"{label}: no {label} is paired."
    said = [reported[(d.device_id, row.name)] for d in devices if (d.device_id, row.name) in reported]
    if said and len(said) == len(devices):
        # What the device itself answered last time: a denied system permission is a step the
        # owner can take in Settings; a blocked or absent capability is unavailable.
        status, reason = min(said, key=lambda item: _RANK.index(item[0]) if item[0] in _RANK else len(_RANK))
        hint = "allow it in Settings" if status is S.MANUAL_USER_STEP else "not available on this device"
        return status, f"{label}: {hint}{f' ({reason})' if reason else ''}."
    if any(row.name in d.capabilities for d in devices):
        return base, f"{label}: {base.value}. {extra}".strip()
    if any(not d.capabilities for d in devices):
        return base, f"{label}: {base.value}, not yet confirmed by the app. {extra}".strip()
    return S.UNAVAILABLE, f"{label}: the app does not report it (older app or OS, or the permission is off)."


def device_tool_capabilities(
    known: Sequence[KnownDevice], reported: Reported | None = None
) -> list[Capability]:
    caps: list[Capability] = []
    for row in ROWS:
        results = [_platform_status(row, p, known, reported or {}) for p in sorted(row.platforms)]
        status = min((s for s, _ in results), key=_RANK.index)
        caps.append(
            Capability(
                id=row.name,
                title=row.description.rstrip("."),
                domain="devices",
                status=status,
                integration_level=IntegrationLevel.DEEP_LINK_HANDOFF
                if status is S.MANUAL_USER_STEP
                else None,
                requires=[row.native_api, f"permission:{row.permission}"],
                note=" ".join(note for _, note in results),
            )
        )
    return caps


def static_capabilities() -> list[Capability]:
    caps = [
        Capability(
            id=f"devices.restricted.{key}",
            title=title,
            domain="devices",
            status=S.RESTRICTED_BY_IOS,
            integration_level=IntegrationLevel.UNAVAILABLE,
            note="No public Apple API lets a third-party app do this.",
        )
        for key, title in RESTRICTED_BY_IOS
    ]
    caps += [
        Capability(
            id="devices.setup.action_button",
            title="Start ZORO from the Action Button",
            domain="devices",
            status=S.MANUAL_USER_STEP,
            requires=["Settings > Action Button > Shortcut > Ask ZORO"],
            note="The owner assigns it once in Settings; apps cannot set it themselves.",
        ),
        Capability(
            id="devices.notes.via_shortcut",
            title="Create Apple Notes",
            domain="devices",
            status=S.MANUAL_USER_STEP,
            integration_level=IntegrationLevel.MANUAL_FALLBACK,
            requires=["A Shortcut the owner makes that adds a note", "device.shortcut.run"],
            note="Apple Notes has no public write API; ZORO runs the owner's Shortcut instead.",
        ),
    ]
    return caps


def home_assistant_capabilities(config: HomeAssistantConfig) -> list[Capability]:
    if not config.enabled:
        status, note = S.REQUIRES_CREDENTIALS, "Set HOME_ASSISTANT_URL and HOME_ASSISTANT_TOKEN to enable."
    elif not config.entities:
        status, note = S.WORKING_INTEGRATION, "Credentials present but no entity is allowlisted yet."
    else:
        status = S.WORKING_INTEGRATION
        note = (
            f"Credentials present; {len(config.entities)} allowlisted entities; reachability is not checked."
        )
    return [
        Capability(
            id=tool,
            title=title,
            domain="home",
            status=status,
            integration_level=IntegrationLevel.OFFICIAL_API,
            requires=[ENV_URL, ENV_TOKEN, "HOME_ASSISTANT_ENTITIES or config/home_assistant.yaml"],
            note=note,
        )
        for tool, title in (
            ("homeassistant.call_service", "Control allowlisted Home Assistant devices"),
            ("homeassistant.get_state", "Read allowlisted Home Assistant states"),
        )
    ]
