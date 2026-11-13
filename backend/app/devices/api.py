"""`/v1/devices`: the device channel (WebSocket), the device list and the REST result fallback.

Thin glue only; the logic lives in `DeviceHub`.
"""

from __future__ import annotations

from fastapi import APIRouter, WebSocket
from starlette.websockets import WebSocketState

from app.api.deps import CurrentDevice, Registry
from app.core.errors import BadRequest, Forbidden, NotFound, ZoroError
from app.devices.hub import CLOSE_POLICY, DeviceConnection, DeviceHub
from app.devices.schemas import DeviceActionAck
from app.schemas.auth import DeviceInfo
from app.schemas.common import Page
from app.schemas.turns import DeviceActionResult
from app.security.sessions import AuthedDevice


class DeviceActionExpired(ZoroError):
    code = "device_action_expired"
    status = 410
    default_message = "This device action expired before its result arrived."


def channel_token(ws: WebSocket) -> str | None:
    """Bearer token from the Authorization header, else the `token` query parameter."""
    scheme, _, value = ws.headers.get("authorization", "").partition(" ")
    if scheme.lower() == "bearer" and value.strip():
        return value.strip()
    token = ws.query_params.get("token", "").strip()
    return token or None


async def authenticate_channel(ws: WebSocket, reg: Registry) -> AuthedDevice | None:
    token = channel_token(ws)
    if token is None:
        return None
    try:
        device: AuthedDevice = await reg.service("sessions").authenticate(token)
    except ZoroError:
        return None
    return device


def build_router(hub: DeviceHub) -> APIRouter:
    router = APIRouter(prefix="/devices", tags=["devices"])

    @router.get("", response_model=Page[DeviceInfo])
    async def list_devices(reg: Registry, device: CurrentDevice) -> Page[DeviceInfo]:
        records = await reg.service("devices").list(include_revoked=False)
        return Page[DeviceInfo](items=[r.to_info(online=hub.is_online(r.id)) for r in records])

    @router.post("/actions/{action_id}/result", response_model=DeviceActionAck)
    async def post_result(action_id: str, body: DeviceActionResult, device: CurrentDevice) -> DeviceActionAck:
        if body.action_id != action_id:
            raise BadRequest("The result is for a different action.", code="action_id_mismatch")
        status = await hub.submit_result(device.device_id, body)
        if status == "accepted" or status == "duplicate":
            return DeviceActionAck(action_id=action_id, status=status)
        if status == "expired":
            raise DeviceActionExpired()
        if status == "wrong_device":
            raise Forbidden("This action was sent to another device.", code="wrong_device")
        raise NotFound("No device action is waiting for this result.", code="device_action_not_found")

    @router.websocket("/channel")
    async def channel(ws: WebSocket, reg: Registry) -> None:
        device = await authenticate_channel(ws, reg)
        if device is None:
            await ws.close(code=CLOSE_POLICY, reason="unauthorized")
            return
        await ws.accept()
        now = reg.service("clock").now()

        async def close(code: int, reason: str) -> None:
            if ws.client_state is not WebSocketState.DISCONNECTED:
                await ws.close(code=code, reason=reason)

        conn = DeviceConnection(
            device_id=device.device_id,
            session_id=device.session_id,
            platform=device.platform,
            name=device.name,
            send=ws.send_json,
            close=close,
            connected_at=now,
            last_frame_at=now,
            capabilities=device.capabilities,
        )
        await hub.connect(conn)
        try:
            while True:
                message = await ws.receive()
                if message["type"] == "websocket.disconnect":
                    break
                text = message.get("text")
                if not await hub.handle_text(conn, text if isinstance(text, str) else ""):
                    break
        finally:
            await hub.disconnect(conn)

    return router
