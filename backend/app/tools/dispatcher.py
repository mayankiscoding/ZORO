"""How the executor reaches a device other than the one that made the request."""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from app.schemas.turns import DeviceActionRequest, DeviceActionResult


class DeviceOffline(Exception):
    """The request did not reach the target device (no live channel, revoked session, expired
    before it was sent). Nothing ran, so the call may be retried."""

    delivered = False


class DeviceNoAnswer(DeviceOffline):
    """The request was delivered but no result came back in time. The device may have acted:
    the outcome is unknown and the call must not be retried automatically."""

    delivered = True


@runtime_checkable
class DeviceDispatcher(Protocol):
    def is_online(self, device_id: str) -> bool:
        """True when the device has a live channel right now."""
        ...

    # `timeout` is the argument name the design spec gives this method.
    async def dispatch(
        self,
        device_id: str,
        request: DeviceActionRequest,
        timeout: float,  # noqa: ASYNC109
    ) -> DeviceActionResult:
        """Push `request` over the device's channel and wait up to `timeout` seconds for its
        result. Raise `DeviceOffline` when it could not be delivered and `DeviceNoAnswer` when it
        was delivered and no result arrived in time."""
        ...


class NullDeviceDispatcher:
    """Default until the devices package installs a real one: every device is offline."""

    def is_online(self, device_id: str) -> bool:
        return False

    # `timeout` is the argument name the design spec gives this method.
    async def dispatch(
        self,
        device_id: str,
        request: DeviceActionRequest,
        timeout: float,  # noqa: ASYNC109
    ) -> DeviceActionResult:
        raise DeviceOffline(device_id)
