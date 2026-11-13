"""Device sessions: challenge -> signature -> short-lived JWT (HS256, `sub` = device id, `sid`).

No refresh tokens: the device signs a new challenge. Every request re-checks the session row and
the device, so revoking a device or flipping the kill switch ends sessions immediately.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import jwt
from sqlalchemy import delete, update

from app.core.clock import Clock, SystemClock
from app.core.errors import ChallengeInvalid, InvalidSignature, TokenInvalid
from app.core.ids import new_id, new_token
from app.core.types import DevicePlatform
from app.db.session import SessionFactory, affected_rows
from app.schemas.auth import ChallengeResponse, TokenRequest, TokenResponse
from app.security.crypto import auth_message, keyed_hash, verify_signature
from app.security.devices import DeviceRegistry
from app.security.models import AuthChallenge, DeviceSession

JWT_ALGORITHM = "HS256"
JWT_ISSUER = "zoro"
CHALLENGE_TTL_SECONDS = 120


@dataclass(frozen=True)
class AuthedDevice:
    """The authenticated caller of a request."""

    device_id: str
    session_id: str
    name: str
    platform: DevicePlatform
    capabilities: tuple[str, ...]
    expires_at: datetime


class SessionService:
    def __init__(
        self,
        session_factory: SessionFactory,
        devices: DeviceRegistry,
        *,
        secret: bytes,
        ttl_seconds: int = 900,
        clock: Clock | None = None,
        challenge_ttl_seconds: int = CHALLENGE_TTL_SECONDS,
    ) -> None:
        if len(secret) < 32:
            raise ValueError("session signing key must be at least 32 bytes")
        self._sf = session_factory
        self._devices = devices
        self._secret = secret
        self._ttl = ttl_seconds
        self._clock = clock or SystemClock()
        self._challenge_ttl = challenge_ttl_seconds

    # ------------------------------------------------------------ challenge

    async def create_challenge(self, device_id: str) -> ChallengeResponse:
        await self._devices.require_active(device_id)
        now = self._clock.now()
        nonce = new_token(32)
        expires_at = now + timedelta(seconds=self._challenge_ttl)
        async with self._sf() as session:
            await session.execute(delete(AuthChallenge).where(AuthChallenge.expires_at < now))
            session.add(
                AuthChallenge(
                    nonce_hash=keyed_hash(self._secret, nonce), device_id=device_id, expires_at=expires_at
                )
            )
            await session.commit()
        return ChallengeResponse(nonce=nonce, expires_at=expires_at)

    # ------------------------------------------------------------ token

    async def issue_token(self, request: TokenRequest) -> TokenResponse:
        """Consume the challenge (single use, even on a bad signature), verify the auth-key
        signature over ``zoro-auth-v1|{device_id}|{nonce}`` and mint the session JWT."""
        device = await self._devices.require_active(request.device_id)
        now = self._clock.now()
        async with self._sf() as session:
            claimed = await session.execute(
                update(AuthChallenge)
                .where(
                    AuthChallenge.nonce_hash == keyed_hash(self._secret, request.nonce),
                    AuthChallenge.device_id == request.device_id,
                    AuthChallenge.used_at.is_(None),
                    AuthChallenge.expires_at > now,
                )
                .values(used_at=now)
            )
            await session.commit()
        if affected_rows(claimed) != 1:
            raise ChallengeInvalid()
        message = auth_message(request.device_id, request.nonce)
        if not verify_signature(device.auth_public_key_b64, message, request.signature_b64):
            raise InvalidSignature()

        sid = new_id("ses")
        expires_at = now + timedelta(seconds=self._ttl)
        async with self._sf() as session:
            await session.execute(delete(DeviceSession).where(DeviceSession.expires_at < now))
            session.add(DeviceSession(id=sid, device_id=device.id, issued_at=now, expires_at=expires_at))
            await session.commit()
        claims: dict[str, Any] = {
            "iss": JWT_ISSUER,
            "sub": device.id,
            "sid": sid,
            "iat": int(now.timestamp()),
            "exp": int(expires_at.timestamp()),
        }
        token = jwt.encode(claims, self._secret, algorithm=JWT_ALGORITHM)
        await self._devices.touch(device.id)
        return TokenResponse(access_token=token, expires_in=self._ttl)

    async def authenticate(self, token: str) -> AuthedDevice:
        """Validate a bearer token: signature, expiry (against the injected clock), live session
        row, device not revoked. Raises `TokenInvalid` or `DeviceRevoked`."""
        try:
            claims = jwt.decode(
                token,
                self._secret,
                algorithms=[JWT_ALGORITHM],
                issuer=JWT_ISSUER,
                options={"verify_exp": False, "verify_iat": False, "require": ["exp", "sub", "sid", "iss"]},
            )
        except jwt.PyJWTError as exc:
            raise TokenInvalid() from exc
        device_id, sid, exp = claims.get("sub"), claims.get("sid"), claims.get("exp")
        if not isinstance(device_id, str) or not isinstance(sid, str) or not isinstance(exp, int):
            raise TokenInvalid()
        now = self._clock.now()
        if datetime.fromtimestamp(exp, UTC) <= now:
            raise TokenInvalid()
        async with self._sf() as session:
            row = await session.get(DeviceSession, sid)
        if row is None or row.device_id != device_id or row.revoked_at is not None or row.expires_at <= now:
            raise TokenInvalid()
        device = await self._devices.get(device_id)
        if device is None:
            raise TokenInvalid()
        if device.revoked:
            raise TokenInvalid("This device was revoked. Pair it again to continue.", code="device_revoked")
        return AuthedDevice(
            device_id=device.id,
            session_id=sid,
            name=device.name,
            platform=device.platform,
            capabilities=device.capabilities,
            expires_at=row.expires_at,
        )

    # ------------------------------------------------------------ revocation

    async def revoke_session(self, session_id: str) -> None:
        async with self._sf() as session:
            await session.execute(
                update(DeviceSession)
                .where(DeviceSession.id == session_id, DeviceSession.revoked_at.is_(None))
                .values(revoked_at=self._clock.now())
            )
            await session.commit()

    async def revoke_all(self) -> int:
        async with self._sf() as session:
            result = await session.execute(
                update(DeviceSession)
                .where(DeviceSession.revoked_at.is_(None))
                .values(revoked_at=self._clock.now())
            )
            await session.commit()
            return affected_rows(result)
