"""`SignedProof` verification for security-sensitive settings changes.

Signed bytes: ``zoro-action-v1|{action}|{subject}|{signed_at}``. Accepted clock skew: 120 s.
A proof is accepted once: the replay guard is keyed on what was signed (not on the signature
bytes, because ECDSA signatures are malleable).
"""

from __future__ import annotations

from datetime import timedelta
from typing import Literal

from sqlalchemy import delete
from sqlalchemy.exc import IntegrityError

from app.core.clock import Clock, SystemClock
from app.core.errors import DeviceNotFound, DeviceRevoked, ProofInvalid, ProofReplayed, ProofStale
from app.core.ids import sha256_hex
from app.db.session import SessionFactory
from app.schemas.common import SignedProof
from app.security.crypto import action_message, verify_signature
from app.security.devices import DeviceRecord, DeviceRegistry
from app.security.models import UsedProof

PROOF_SKEW_SECONDS = 120
ProofKey = Literal["approval", "auth"]


class ProofVerifier:
    def __init__(
        self,
        session_factory: SessionFactory,
        devices: DeviceRegistry,
        *,
        clock: Clock | None = None,
        skew_seconds: int = PROOF_SKEW_SECONDS,
    ) -> None:
        self._sf = session_factory
        self._devices = devices
        self._clock = clock or SystemClock()
        self._skew = timedelta(seconds=skew_seconds)

    async def verify(
        self,
        proof: SignedProof,
        *,
        action: str,
        subject: str,
        require_key: ProofKey = "approval",
        expected_device_id: str | None = None,
    ) -> DeviceRecord:
        """Check a proof for exactly this `action` and `subject`; return the signing device.

        Raises `ProofInvalid` (wrong device, wrong key, bad signature), `ProofStale` (outside the
        skew window) or `ProofReplayed`. `expected_device_id` ties the proof to the session's
        device.
        """
        if "|" in action:
            raise ProofInvalid()
        if expected_device_id is not None and proof.device_id != expected_device_id:
            raise ProofInvalid("The proof was signed by a different device than the one signed in.")
        if proof.key != require_key:
            raise ProofInvalid(f"This action needs a proof signed with the {require_key} key.")
        try:
            device = await self._devices.require_active(proof.device_id)
        except (DeviceNotFound, DeviceRevoked) as exc:
            raise ProofInvalid("The signing device is not an active paired device.") from exc

        now = self._clock.now()
        if abs(now - proof.signed_at) > self._skew:
            raise ProofStale()

        message = action_message(action, subject, proof.signed_at)
        public_key = (
            device.approval_public_key_b64 if require_key == "approval" else device.auth_public_key_b64
        )
        if not verify_signature(public_key, message, proof.signature_b64):
            raise ProofInvalid()

        digest = sha256_hex(f"{device.id}|{require_key}|{message}")
        async with self._sf() as session:
            await session.execute(delete(UsedProof).where(UsedProof.signed_at < now - 2 * self._skew))
            session.add(UsedProof(digest=digest, device_id=device.id, signed_at=proof.signed_at))
            try:
                await session.commit()
            except IntegrityError as exc:
                await session.rollback()
                raise ProofReplayed() from exc
        return device
