"""Target selection: explicit device, requester, most recent online device of the right platform."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

from app.core.types import DevicePlatform
from app.devices.contract import platforms_for
from app.devices.targeting import select_target
from app.plugins import PluginRegistry
from app.security.devices import DeviceRecord
from tests.conftest import PairDevice
from tests.devices.conftest import NOW, FakeChannel, hub_of, signed_in_conn

IOS, MAC = DevicePlatform.IOS, DevicePlatform.MACOS


def dev(
    device_id: str,
    platform: DevicePlatform,
    minutes_ago: int,
    caps: tuple[str, ...] = (),
    revoked: bool = False,
) -> DeviceRecord:
    return DeviceRecord(
        id=device_id, name=device_id, platform=platform, auth_public_key_b64="", approval_public_key_b64="",
        capabilities=caps, app_version=None, last_seen_at=NOW - timedelta(minutes=minutes_ago),
        revoked_at=NOW if revoked else None,
    )  # fmt: skip


PHONE = dev("phone", IOS, 1)
MAC_OLD = dev("mac_old", MAC, 300)
MAC_NEW = dev("mac_new", MAC, 5)
MAC_LIMITED = dev("mac_limited", MAC, 0, caps=("mac.file.open",))
ALL = [PHONE, MAC_OLD, MAC_NEW, MAC_LIMITED]


def choose(tool: str, online: set[str], **kwargs: Any) -> tuple[str | None, str | None, str | None]:
    choice = select_target(
        ALL, tool_name=tool, platforms=platforms_for(tool), is_online=online.__contains__, **kwargs
    )
    return (choice.device.id if choice.device else None, choice.reason, choice.problem)


def test_explicit_device_wins_and_is_checked() -> None:
    assert choose("device.open_url", set(), explicit_device_id="mac_old", requesting_device_id="phone") == (
        "mac_old",
        "explicit",
        None,
    )
    assert choose("device.open_url", set(), explicit_device_id="nope") == (None, None, "unknown_device")
    assert choose("ios.alarm.create", set(), explicit_device_id="mac_new") == (
        None,
        None,
        "unsupported_on_device",
    )
    assert choose("mac.file.search", set(), explicit_device_id="mac_limited") == (
        None,
        None,
        "unsupported_on_device",
    )
    revoked = select_target(
        [dev("gone", MAC, 1, revoked=True)],
        tool_name="mac.file.open",
        platforms=platforms_for("mac.file.open"),
        is_online=lambda _: True,
        explicit_device_id="gone",
    )
    assert revoked.problem == "device_revoked"


def test_requester_when_it_supports_the_tool() -> None:
    assert choose("device.open_url", set(), requesting_device_id="phone") == ("phone", "requester", None)
    assert choose("ios.alarm.create", set(), requesting_device_id="phone") == ("phone", "requester", None)


def test_on_my_mac_picks_most_recent_online_mac() -> None:
    assert choose("device.open_url", {"mac_old"}, requesting_device_id="phone", platform=MAC) == (
        "mac_old",
        "platform_recent",
        None,
    )
    assert choose("device.open_url", {"mac_old", "mac_new"}, requesting_device_id="phone", platform=MAC) == (
        "mac_new",
        "platform_recent",
        None,
    )
    # nobody online: the most recently seen Mac that can run it
    assert choose("mac.file.search", set(), requesting_device_id="phone")[0] == "mac_new"
    assert choose("ios.alarm.create", set(), requesting_device_id="mac_new", platform=MAC) == (
        None,
        None,
        "unsupported_on_device",
    )


def test_requester_cannot_run_falls_back_by_platform() -> None:
    assert choose("ios.timer.start", set(), requesting_device_id="mac_new") == ("phone", "recent", None)
    assert choose("ios.timer.start", {"phone"}, requesting_device_id="mac_new") == (
        "phone",
        "platform_recent",
        None,
    )
    nobody = select_target(
        [MAC_NEW],
        tool_name="ios.timer.start",
        platforms=platforms_for("ios.timer.start"),
        is_online=lambda _: False,
    )
    assert nobody.problem == "no_device"


async def test_hub_choose_target_uses_registry_and_presence(
    registry: PluginRegistry, pair_device: PairDevice
) -> None:
    phone = await pair_device(name="Phone")
    mac = await pair_device(name="Mac", platform=MAC)
    hub = hub_of(registry)
    await hub.connect(await signed_in_conn(registry, mac.token, FakeChannel()))
    choice = await hub.choose_target(
        "device.open_url",
        platforms_for("device.open_url"),
        requesting_device_id=phone.device_id,
        platform=MAC,
    )
    assert choice.device is not None and choice.device.id == mac.device_id and choice.online
    plain = await hub.choose_target(
        "device.open_url", platforms_for("device.open_url"), requesting_device_id=phone.device_id
    )
    assert plain.device is not None and plain.device.id == phone.device_id
