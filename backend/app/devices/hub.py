"""DeviceHub: live channels to paired devices, and the kernel's `DeviceDispatcher`.

Frames (JSON text, see the end of `app/schemas/turns.py`):
  server -> device  {"type": "device_action", "action": DeviceActionRequest}
                    {"type": "approval_required", "approval": ApprovalRequest}
  device -> server  {"type": "hello", "capabilities": [...]}
                    {"type": "device_action_result", "result": DeviceActionResult}
                    {"type": "ping"}

The hub is transport-agnostic: the WebSocket route hands it a `DeviceConnection` with `send` and
`close` callables, then every text frame. A device is *online* while it has a channel whose last
frame is younger than `stale_after_s` (apps ping about every 30 s). A result is matched to its
pending action by `action_id` and target device; a second result for the same action, a result
for an action that already timed out, or one from another device is never applied twice.
A result can also arrive over REST (`POST /v1/devices/actions/{id}/result`) when the socket drops.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from collections import OrderedDict
from collections.abc import Awaitable, Callable, Iterable
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Literal

from pydantic import ValidationError

from app.core.clock import Clock
from app.core.ids import new_id
from app.core.types import CapabilityStatus, DevicePlatform
from app.devices.schemas import DevicePresence
from app.devices.targeting import TargetChoice, select_target
from app.schemas.turns import ApprovalRequest, DeviceActionRequest, DeviceActionResult
from app.security.devices import DeviceRegistry
from app.tools.dispatcher import DeviceNoAnswer, DeviceOffline

log = logging.getLogger(__name__)

SendFrame = Callable[[dict[str, Any]], Awaitable[None]]
CloseChannel = Callable[[int, str], Awaitable[None]]
SubmitStatus = Literal["accepted", "duplicate", "unknown", "expired", "wrong_device"]

MAX_FRAME_BYTES = 256 * 1024
MAX_CAPABILITIES = 200
MAX_BAD_FRAMES = 20
_RECENT = 2048
CLOSE_POLICY = 1008
CLOSE_REPLACED = 4000
CLOSE_GOING_AWAY = 1001


@dataclass
class DeviceConnection:
    device_id: str
    session_id: str
    platform: DevicePlatform
    name: str
    send: SendFrame
    close: CloseChannel
    connected_at: datetime
    last_frame_at: datetime
    capabilities: tuple[str, ...] = ()
    hello_received: bool = False
    bad_frames: int = 0
    conn_id: str = field(default_factory=lambda: new_id("chn"))


Authorize = Callable[[DeviceConnection], Awaitable[bool]]


@dataclass
class _Pending:
    device_id: str
    request: DeviceActionRequest
    future: asyncio.Future[DeviceActionResult]


@dataclass(frozen=True)
class KnownDevice:
    device_id: str
    platform: DevicePlatform
    capabilities: tuple[str, ...]


class _Recent(OrderedDict[str, Any]):
    """A bounded insertion-ordered memory of finished or expired action ids."""

    def remember(self, key: str, value: Any = None) -> None:
        self[key] = value
        self.move_to_end(key)
        while len(self) > _RECENT:
            self.popitem(last=False)


class DeviceHub:
    """Registered as service ``device_hub`` and as the kernel device dispatcher."""

    def __init__(
        self,
        *,
        clock: Clock,
        devices: DeviceRegistry | None = None,
        authorize: Authorize | None = None,
        stale_after_s: float = 120.0,
    ) -> None:
        self._clock = clock
        self._devices = devices
        self._authorize = authorize
        self._stale_after_s = stale_after_s
        self._conns: dict[str, DeviceConnection] = {}
        self._pending: dict[str, _Pending] = {}
        self._finished = _Recent()  # action_id -> DeviceActionResult
        self._expired = _Recent()
        self._known: dict[str, KnownDevice] = {}
        # (device id, tool) -> (status, reason) from the last result that carried one, so the
        # capability registry can say "allow it in Settings" or "not available on this device".
        self._reported: dict[tuple[str, str], tuple[CapabilityStatus, str]] = {}

    # ------------------------------------------------------------ presence

    def _fresh(self, conn: DeviceConnection) -> bool:
        return (self._clock.now() - conn.last_frame_at).total_seconds() <= self._stale_after_s

    def is_online(self, device_id: str) -> bool:
        conn = self._conns.get(device_id)
        return conn is not None and self._fresh(conn)

    def connection(self, device_id: str) -> DeviceConnection | None:
        return self._conns.get(device_id)

    def capabilities(self, device_id: str) -> tuple[str, ...]:
        conn = self._conns.get(device_id)
        if conn is not None and conn.hello_received:
            return conn.capabilities
        known = self._known.get(device_id)
        return known.capabilities if known is not None else ()

    def presence(self) -> list[DevicePresence]:
        return [
            DevicePresence(
                device_id=conn.device_id,
                platform=conn.platform,
                online=self._fresh(conn),
                connected_at=conn.connected_at,
                last_frame_at=conn.last_frame_at,
                capabilities=list(conn.capabilities),
            )
            for conn in sorted(self._conns.values(), key=lambda c: c.device_id)
        ]

    def known_devices(self) -> list[KnownDevice]:
        """Paired, non-revoked devices with their last known capabilities (for the capability registry)."""
        return sorted(self._known.values(), key=lambda d: d.device_id)

    async def refresh_known(self) -> None:
        if self._devices is None:
            return
        records = await self._devices.list(include_revoked=False)
        self._known = {r.id: KnownDevice(r.id, r.platform, r.capabilities) for r in records}

    # ------------------------------------------------------------ channel lifecycle

    async def connect(self, conn: DeviceConnection) -> None:
        """Attach a channel. A newer channel of the same device replaces the older one."""
        previous = self._conns.get(conn.device_id)
        self._conns[conn.device_id] = conn
        self._known.setdefault(conn.device_id, KnownDevice(conn.device_id, conn.platform, conn.capabilities))
        if previous is not None and previous.conn_id != conn.conn_id:
            with contextlib.suppress(Exception):
                await previous.close(CLOSE_REPLACED, "replaced_by_new_channel")
        log.info("device channel open", extra={"device_id": conn.device_id})

    async def disconnect(self, conn: DeviceConnection) -> None:
        """Detach a channel. Pending actions keep waiting: the result may still come over REST."""
        current = self._conns.get(conn.device_id)
        if current is not None and current.conn_id == conn.conn_id:
            del self._conns[conn.device_id]
            log.info("device channel closed", extra={"device_id": conn.device_id})

    async def close_all(self) -> None:
        for pending in list(self._pending.values()):
            if not pending.future.done():
                pending.future.set_exception(DeviceOffline(pending.device_id))
        for conn in list(self._conns.values()):
            with contextlib.suppress(Exception):
                await conn.close(CLOSE_GOING_AWAY, "server_shutdown")
        self._conns.clear()

    # ------------------------------------------------------------ frames from the device

    async def handle_text(self, conn: DeviceConnection, text: str) -> bool:
        """Process one frame. Returns False when the channel must close (it is then closed)."""
        if self._authorize is not None and not await self._authorize(conn):
            await self._drop(conn, "session_revoked")
            return False
        frame = self._decode(text)
        if frame is None:
            conn.bad_frames += 1
            if conn.bad_frames >= MAX_BAD_FRAMES:
                await self._drop(conn, "too_many_bad_frames")
                return False
            return True
        conn.last_frame_at = self._clock.now()
        if self._devices is not None:
            await self._devices.touch(conn.device_id)
        kind = frame.get("type")
        if kind == "hello":
            await self._hello(conn, frame.get("capabilities"))
        elif kind == "device_action_result":
            try:
                result = DeviceActionResult.model_validate(frame.get("result"))
            except ValidationError:
                conn.bad_frames += 1
                return True
            await self.submit_result(conn.device_id, result)
        elif kind != "ping":
            conn.bad_frames += 1
        return True

    @staticmethod
    def _decode(text: str) -> dict[str, Any] | None:
        if len(text.encode("utf-8")) > MAX_FRAME_BYTES:
            return None
        try:
            frame = json.loads(text)
        except ValueError:
            return None
        return frame if isinstance(frame, dict) and isinstance(frame.get("type"), str) else None

    async def _hello(self, conn: DeviceConnection, raw: Any) -> None:
        names = raw if isinstance(raw, list) else []
        caps = tuple(sorted({c for c in names if isinstance(c, str) and 0 < len(c) <= 100}))[
            :MAX_CAPABILITIES
        ]
        conn.capabilities = caps
        conn.hello_received = True
        self._known[conn.device_id] = KnownDevice(conn.device_id, conn.platform, caps)
        if self._devices is not None:
            record = await self._devices.get(conn.device_id)
            if record is not None and tuple(record.capabilities) != caps:
                await self._devices.set_capabilities(conn.device_id, caps)

    async def _drop(self, conn: DeviceConnection, reason: str) -> None:
        await self.disconnect(conn)
        with contextlib.suppress(Exception):
            await conn.close(CLOSE_POLICY, reason)

    # ------------------------------------------------------------ results

    async def submit_result(self, device_id: str, result: DeviceActionResult) -> SubmitStatus:
        """Match a result to its pending action. Idempotent: the first result wins."""
        action_id = result.action_id
        if action_id in self._finished:
            return "duplicate"
        pending = self._pending.get(action_id)
        if pending is not None:
            if pending.device_id != device_id:
                log.warning("result from the wrong device ignored", extra={"action_id": action_id})
                return "wrong_device"
            if pending.future.done():
                return "duplicate"
            if pending.request.expires_at <= self._clock.now():
                self._expired.remember(action_id)
                pending.future.set_exception(DeviceOffline(f"{device_id}: action expired"))
                return "expired"
            self._finished.remember(action_id, result)
            self._note_capability(device_id, pending.request.tool, result)
            pending.future.set_result(result)
            return "accepted"
        if action_id in self._expired:
            return "expired"
        return "unknown"

    def _note_capability(self, device_id: str, tool: str, result: DeviceActionResult) -> None:
        """A denied system permission is `manual_user_step` (the owner can grant it in Settings);
        a blocked or absent capability is `unavailable`. A success clears the note."""
        key = (device_id, tool)
        if result.ok:
            self._reported.pop(key, None)
            return
        status = result.capability_status
        if status is None:
            status = {
                "permission_denied": CapabilityStatus.MANUAL_USER_STEP,
                "unsupported": CapabilityStatus.UNAVAILABLE,
            }.get(result.error_code or "")
        if status is not None:
            self._reported[key] = (status, (result.error_message or result.error_code or "")[:200])

    def reported(self) -> dict[tuple[str, str], tuple[CapabilityStatus, str]]:
        return dict(self._reported)

    # ------------------------------------------------------------ dispatch (kernel DeviceDispatcher)

    # `timeout` is the argument name the design spec gives this method.
    async def dispatch(
        self,
        device_id: str,
        request: DeviceActionRequest,
        timeout: float,  # noqa: ASYNC109
    ) -> DeviceActionResult:
        action_id = request.action_id
        done = self._finished.get(action_id)
        if isinstance(done, DeviceActionResult):
            return done  # the same action dispatched again: answer with its result, never re-run
        if action_id in self._expired:
            raise DeviceOffline(f"{device_id}: action expired")
        if request.target_device_id is not None and request.target_device_id != device_id:
            raise DeviceOffline(f"{device_id}: action targets another device")
        existing = self._pending.get(action_id)
        if existing is not None:
            return await self._wait(existing, timeout)

        conn = self._conns.get(device_id)
        if conn is None or not self._fresh(conn):
            raise DeviceOffline(device_id)
        if self._authorize is not None and not await self._authorize(conn):
            await self._drop(conn, "session_revoked")
            raise DeviceOffline(device_id)
        if request.expires_at <= self._clock.now():
            self._expired.remember(action_id)
            raise DeviceOffline(f"{device_id}: action expired")

        pending = _Pending(device_id, request, asyncio.get_running_loop().create_future())
        self._pending[action_id] = pending
        try:
            await conn.send({"type": "device_action", "action": request.model_dump(mode="json")})
        except Exception:
            self._pending.pop(action_id, None)
            await self.disconnect(conn)
            raise DeviceOffline(device_id) from None
        try:
            return await self._wait(pending, timeout)
        finally:
            self._pending.pop(action_id, None)

    async def _wait(self, pending: _Pending, timeout: float) -> DeviceActionResult:  # noqa: ASYNC109
        remaining = (pending.request.expires_at - self._clock.now()).total_seconds()
        try:
            return await asyncio.wait_for(asyncio.shield(pending.future), max(0.0, min(timeout, remaining)))
        except TimeoutError:
            # The device may have acted; a late result is answered "expired" and never applied.
            self._expired.remember(pending.request.action_id)
            raise DeviceNoAnswer(f"{pending.device_id}: no answer in time") from None

    async def choose_target(
        self,
        tool_name: str,
        platforms: frozenset[DevicePlatform],
        *,
        requesting_device_id: str | None = None,
        explicit_device_id: str | None = None,
        platform: DevicePlatform | None = None,
    ) -> TargetChoice:
        """Explicit device, else the requester when it can run the tool, else the most recently
        seen online device of the right platform (`platform` = "on my Mac" / "on my iPhone")."""
        records = await self._devices.list(include_revoked=True) if self._devices is not None else []
        return select_target(
            records,
            tool_name=tool_name,
            platforms=platforms,
            is_online=self.is_online,
            requesting_device_id=requesting_device_id,
            explicit_device_id=explicit_device_id,
            platform=platform,
        )

    def pending_actions(self, device_id: str | None = None) -> list[DeviceActionRequest]:
        return [p.request for p in self._pending.values() if device_id is None or p.device_id == device_id]

    # ------------------------------------------------------------ approvals

    async def push_approval(
        self, approval: ApprovalRequest, device_ids: Iterable[str] | None = None
    ) -> list[str]:
        """Show an approval on online devices (all of them by default). Returns who received it."""
        targets = list(device_ids) if device_ids is not None else list(self._conns)
        frame = {"type": "approval_required", "approval": approval.model_dump(mode="json")}
        reached: list[str] = []
        for device_id in targets:
            conn = self._conns.get(device_id)
            if conn is None or not self._fresh(conn):
                continue
            try:
                await conn.send(frame)
                reached.append(device_id)
            except Exception:
                await self.disconnect(conn)
        return reached
