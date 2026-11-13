"""API models owned by the devices package (the shared contract stays in `app/schemas`)."""

from __future__ import annotations

from typing import Literal

from pydantic import AwareDatetime, Field

from app.core.types import DevicePlatform
from app.schemas.common import ZModel


class DevicePresence(ZModel):
    device_id: str
    platform: DevicePlatform
    online: bool
    connected_at: AwareDatetime
    last_frame_at: AwareDatetime
    capabilities: list[str] = Field(default_factory=list)


class DeviceActionAck(ZModel):
    """Answer to `POST /v1/devices/actions/{action_id}/result`."""

    action_id: str
    status: Literal["accepted", "duplicate"]
