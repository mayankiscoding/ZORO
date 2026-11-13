"""Device pairing and session contract.

Keys are ECDSA P-256. Public keys travel as base64 of the X9.63 uncompressed point (65 bytes).
Signatures are DER, base64, over SHA-256 of the stated UTF-8 string.
"""

from __future__ import annotations

from pydantic import AwareDatetime, Field

from app.core.types import DevicePlatform
from app.schemas.common import ZModel


class PairRequest(ZModel):
    pairing_code: str  # one-time code printed by `python -m app.cli pairing-code`
    device_name: str
    platform: DevicePlatform
    auth_public_key_b64: str  # signs session challenges
    approval_public_key_b64: str  # use requires user presence (Secure Enclave access control)
    capabilities: list[str] = Field(default_factory=list)  # device tool names it can execute
    app_version: str | None = None


class PairResponse(ZModel):
    device_id: str
    server_name: str
    server_time: AwareDatetime


class ChallengeRequest(ZModel):
    device_id: str


class ChallengeResponse(ZModel):
    nonce: str
    expires_at: AwareDatetime


class TokenRequest(ZModel):
    """`signature_b64` signs ``zoro-auth-v1|{device_id}|{nonce}`` with the auth key."""

    device_id: str
    nonce: str
    signature_b64: str


class TokenResponse(ZModel):
    access_token: str
    token_type: str = "bearer"  # noqa: S105 - OAuth token type, not a secret
    expires_in: int  # seconds


class DeviceInfo(ZModel):
    device_id: str
    name: str
    platform: DevicePlatform
    capabilities: list[str] = Field(default_factory=list)
    last_seen_at: AwareDatetime | None = None
    online: bool = False
    revoked: bool = False
