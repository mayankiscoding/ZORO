"""Device registry and pairing.

A device pairs once with a one-time code (10 minutes, stored as a keyed hash) and registers two
P-256 public keys: the auth key (signs session challenges and `confirm` approvals) and the
approval key (use requires user presence; signs `biometric` approvals and security changes).
"""

from __future__ import annotations

import secrets
from collections import deque
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import select, update

from app.core.clock import Clock, SystemClock
from app.core.errors import BadRequest, DeviceNotFound, DeviceRevoked, PairingCodeInvalid, RateLimited
from app.core.ids import new_id
from app.core.types import DevicePlatform
from app.db.session import SessionFactory, affected_rows
from app.schemas.auth import DeviceInfo, PairRequest
from app.security.crypto import keyed_hash, load_public_key
from app.security.models import Device, DeviceSession, PairingCode

PAIRING_CODE_TTL_SECONDS = 600
_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789"  # no 0/O, 1/I/L, U
_CODE_LENGTH = 8
_LAST_SEEN_RESOLUTION = timedelta(seconds=30)
_MAX_FAILURES_PER_MINUTE = 10


@dataclass(frozen=True)
class IssuedPairingCode:
    code: str  # shown once, e.g. "K7QM-2XWD"; only its keyed hash is stored
    expires_at: datetime


@dataclass(frozen=True)
class DeviceRecord:
    id: str
    name: str
    platform: DevicePlatform
    auth_public_key_b64: str
    approval_public_key_b64: str
    capabilities: tuple[str, ...]
    app_version: str | None
    last_seen_at: datetime | None
    revoked_at: datetime | None

    @property
    def revoked(self) -> bool:
        return self.revoked_at is not None

    def to_info(self, *, online: bool = False) -> DeviceInfo:
        return DeviceInfo(
            device_id=self.id,
            name=self.name,
            platform=self.platform,
            capabilities=list(self.capabilities),
            last_seen_at=self.last_seen_at,
            online=online and not self.revoked,
            revoked=self.revoked,
        )


def normalise_code(code: str) -> str:
    return "".join(ch for ch in code.upper() if ch.isalnum())


def _record(row: Device) -> DeviceRecord:
    return DeviceRecord(
        id=row.id,
        name=row.name,
        platform=DevicePlatform(row.platform),
        auth_public_key_b64=row.auth_public_key_b64,
        approval_public_key_b64=row.approval_public_key_b64,
        capabilities=tuple(row.capabilities or ()),
        app_version=row.app_version,
        last_seen_at=row.last_seen_at,
        revoked_at=row.revoked_at,
    )


class DeviceRegistry:
    def __init__(
        self,
        session_factory: SessionFactory,
        *,
        pepper: bytes,
        clock: Clock | None = None,
        code_ttl_seconds: int = PAIRING_CODE_TTL_SECONDS,
    ) -> None:
        self._sf = session_factory
        self._pepper = pepper
        self._clock = clock or SystemClock()
        self._code_ttl = code_ttl_seconds
        self._failures: deque[datetime] = deque(maxlen=_MAX_FAILURES_PER_MINUTE)

    def _check_throttle(self) -> None:
        cutoff = self._clock.now() - timedelta(seconds=60)
        recent = [moment for moment in self._failures if moment > cutoff]
        if len(recent) >= _MAX_FAILURES_PER_MINUTE:
            raise RateLimited("Too many wrong pairing codes. Wait a minute and try again.")

    # ------------------------------------------------------------ pairing

    async def create_pairing_code(self) -> IssuedPairingCode:
        raw = "".join(secrets.choice(_CODE_ALPHABET) for _ in range(_CODE_LENGTH))
        now = self._clock.now()
        expires_at = now + timedelta(seconds=self._code_ttl)
        async with self._sf() as session:
            session.add(
                PairingCode(
                    id=new_id("pc"),
                    code_hash=keyed_hash(self._pepper, raw),
                    created_at=now,
                    expires_at=expires_at,
                )
            )
            await session.commit()
        return IssuedPairingCode(code=f"{raw[:4]}-{raw[4:]}", expires_at=expires_at)

    async def pair(self, request: PairRequest) -> DeviceRecord:
        """Validate the keys, then consume the pairing code atomically and register the device.
        Wrong codes are throttled (10 failures a minute) so the code space cannot be searched."""
        self._check_throttle()
        name = request.device_name.strip()
        if not name or len(name) > 200:
            raise BadRequest("Give the device a name of at most 200 characters.", code="device_name_invalid")
        load_public_key(request.auth_public_key_b64)
        load_public_key(request.approval_public_key_b64)
        if request.auth_public_key_b64 == request.approval_public_key_b64:
            raise BadRequest(
                "The approval key must be a different key from the auth key.", code="public_key_reused"
            )
        now = self._clock.now()
        code = normalise_code(request.pairing_code)
        if len(code) != _CODE_LENGTH:
            self._failures.append(now)
            raise PairingCodeInvalid()

        device_id = new_id("dev")
        async with self._sf() as session:
            claimed = await session.execute(
                update(PairingCode)
                .where(
                    PairingCode.code_hash == keyed_hash(self._pepper, code),
                    PairingCode.used_at.is_(None),
                    PairingCode.expires_at > now,
                )
                .values(used_at=now, used_by_device_id=device_id)
            )
            if affected_rows(claimed) != 1:
                await session.rollback()
                self._failures.append(now)
                raise PairingCodeInvalid()
            row = Device(
                id=device_id,
                name=name,
                platform=request.platform.value,
                auth_public_key_b64=request.auth_public_key_b64,
                approval_public_key_b64=request.approval_public_key_b64,
                capabilities=sorted({c for c in request.capabilities if c}),
                app_version=request.app_version,
                last_seen_at=now,
                created_at=now,
                updated_at=now,
            )
            session.add(row)
            await session.commit()
            return _record(row)

    # ------------------------------------------------------------ lookup

    async def get(self, device_id: str) -> DeviceRecord | None:
        async with self._sf() as session:
            row = await session.get(Device, device_id)
            return _record(row) if row is not None else None

    async def require_active(self, device_id: str) -> DeviceRecord:
        device = await self.get(device_id)
        if device is None:
            raise DeviceNotFound()
        if device.revoked:
            raise DeviceRevoked()
        return device

    async def list(self, *, include_revoked: bool = True) -> list[DeviceRecord]:
        stmt = select(Device).order_by(Device.created_at)
        if not include_revoked:
            stmt = stmt.where(Device.revoked_at.is_(None))
        async with self._sf() as session:
            return [_record(row) for row in (await session.execute(stmt)).scalars().all()]

    # ------------------------------------------------------------ changes

    async def revoke(self, device_id: str) -> DeviceRecord:
        """Revoke the device and end its sessions in one transaction. Idempotent."""
        now = self._clock.now()
        async with self._sf() as session:
            row = await session.get(Device, device_id)
            if row is None:
                raise DeviceNotFound()
            if row.revoked_at is None:
                row.revoked_at = now
            await session.execute(
                update(DeviceSession)
                .where(DeviceSession.device_id == device_id, DeviceSession.revoked_at.is_(None))
                .values(revoked_at=now)
            )
            await session.commit()
            return _record(row)

    async def touch(self, device_id: str) -> None:
        """Record that the device was seen (coarse, to avoid a write per request)."""
        now = self._clock.now()
        async with self._sf() as session:
            row = await session.get(Device, device_id)
            if row is None:
                return
            if row.last_seen_at is None or now - row.last_seen_at >= _LAST_SEEN_RESOLUTION:
                row.last_seen_at = now
                await session.commit()

    async def set_capabilities(self, device_id: str, capabilities: Sequence[str]) -> DeviceRecord:
        async with self._sf() as session:
            row = await session.get(Device, device_id)
            if row is None:
                raise DeviceNotFound()
            row.capabilities = sorted({c for c in capabilities if c})
            await session.commit()
            return _record(row)
