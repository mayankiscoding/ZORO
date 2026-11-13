"""A paired device with software P-256 keys, for tests.

Mirrors what the apps do with Secure Enclave keys: X9.63 public keys, DER signatures over the
exact strings documented in `app/schemas`. Nothing here is a real credential; keys are generated
per instance.
"""

from __future__ import annotations

import base64
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Literal

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.core.types import ApprovalLevel, DevicePlatform
from app.schemas.auth import PairRequest, TokenRequest
from app.schemas.common import SignedProof, iso_seconds
from app.schemas.turns import ApprovalDecision, ApprovalRequest

KeyName = Literal["auth", "approval"]


def _public_b64(key: ec.EllipticCurvePrivateKey) -> str:
    raw = key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    return base64.b64encode(raw).decode("ascii")


class DeviceSigner:
    def __init__(
        self,
        *,
        device_id: str | None = None,
        name: str = "Test iPhone",
        platform: DevicePlatform = DevicePlatform.IOS,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.device_id = device_id
        self.name = name
        self.platform = platform
        self._now = now or (lambda: datetime.now(UTC))
        self._keys: dict[str, ec.EllipticCurvePrivateKey] = {
            "auth": ec.generate_private_key(ec.SECP256R1()),
            "approval": ec.generate_private_key(ec.SECP256R1()),
        }

    # ------------------------------------------------------------ keys

    @property
    def auth_public_key_b64(self) -> str:
        return _public_b64(self._keys["auth"])

    @property
    def approval_public_key_b64(self) -> str:
        return _public_b64(self._keys["approval"])

    def sign(self, message: str, key: KeyName = "auth") -> str:
        """DER ECDSA-SHA256 signature of the UTF-8 message, base64."""
        signature = self._keys[key].sign(message.encode("utf-8"), ec.ECDSA(hashes.SHA256()))
        return base64.b64encode(signature).decode("ascii")

    def _require_id(self) -> str:
        if self.device_id is None:
            raise RuntimeError("pair the device first (device_id is not set)")
        return self.device_id

    # ------------------------------------------------------------ pairing and sessions

    def pair_request(self, pairing_code: str, capabilities: list[str] | None = None) -> PairRequest:
        return PairRequest(
            pairing_code=pairing_code,
            device_name=self.name,
            platform=self.platform,
            auth_public_key_b64=self.auth_public_key_b64,
            approval_public_key_b64=self.approval_public_key_b64,
            capabilities=capabilities or [],
            app_version="test",
        )

    def sign_auth(self, nonce: str, *, key: KeyName = "auth") -> TokenRequest:
        """Signs ``zoro-auth-v1|{device_id}|{nonce}``."""
        device_id = self._require_id()
        return TokenRequest(
            device_id=device_id,
            nonce=nonce,
            signature_b64=self.sign(f"zoro-auth-v1|{device_id}|{nonce}", key),
        )

    # ------------------------------------------------------------ approvals and proofs

    def sign_approval(
        self,
        request: ApprovalRequest,
        approved: bool = True,
        *,
        key: KeyName | None = None,
        signed_at: datetime | None = None,
        action_digest: str | None = None,
    ) -> ApprovalDecision:
        """Signs ``zoro-approval-v1|{approval_id}|{action_digest}|{1 or 0}|{signed_at}``.

        By default the right key for the level is used (approval key for `biometric`, auth key
        otherwise). `key` and `action_digest` let a test produce a wrong decision on purpose.
        """
        chosen: KeyName = key or ("approval" if request.level is ApprovalLevel.BIOMETRIC else "auth")
        moment = (signed_at or self._now()).replace(microsecond=0)
        digest = action_digest or request.action_digest
        message = f"zoro-approval-v1|{request.approval_id}|{digest}|{'1' if approved else '0'}|{iso_seconds(moment)}"
        return ApprovalDecision(
            approval_id=request.approval_id,
            approved=approved,
            action_digest=digest,
            device_id=self._require_id(),
            signed_at=moment,
            signature_b64=self.sign(message, chosen),
        )

    def sign_proof(
        self, action: str, subject: str, *, key: KeyName = "approval", signed_at: datetime | None = None
    ) -> SignedProof:
        """Signs ``zoro-action-v1|{action}|{subject}|{signed_at}``."""
        moment = (signed_at or self._now()).replace(microsecond=0)
        message = f"zoro-action-v1|{action}|{subject}|{iso_seconds(moment)}"
        return SignedProof(
            device_id=self._require_id(), signed_at=moment, signature_b64=self.sign(message, key), key=key
        )
