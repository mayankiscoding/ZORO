"""Signature verification (ECDSA P-256 / SHA-256) and field encryption (AES-256-GCM).

Wire formats (see `app/schemas/auth.py` and `app/schemas/common.py`):
- public key: base64 of the 65-byte X9.63 uncompressed point;
- signature: base64 of the DER-encoded ECDSA signature over SHA-256 of a UTF-8 string.
"""

from __future__ import annotations

import base64
import binascii
import hmac
import os
from datetime import datetime
from hashlib import sha256

from cryptography.exceptions import InvalidSignature as _CryptoInvalidSignature
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.core.errors import DecryptionFailed, PublicKeyInvalid
from app.schemas.common import iso_seconds

_X963_LENGTH = 65
_NONCE_BYTES = 12
_CIPHER_PREFIX = "v1."

# ---------------------------------------------------------------- exact signed strings


def auth_message(device_id: str, nonce: str) -> str:
    return f"zoro-auth-v1|{device_id}|{nonce}"


def approval_message(approval_id: str, action_digest: str, approved: bool, signed_at: datetime) -> str:
    return (
        f"zoro-approval-v1|{approval_id}|{action_digest}|{'1' if approved else '0'}|{iso_seconds(signed_at)}"
    )


def action_message(action: str, subject: str, signed_at: datetime) -> str:
    return f"zoro-action-v1|{action}|{subject}|{iso_seconds(signed_at)}"


# ---------------------------------------------------------------- P-256


def load_public_key(public_key_b64: str) -> ec.EllipticCurvePublicKey:
    """Parse a base64 X9.63 uncompressed P-256 point. Raises `PublicKeyInvalid`."""
    try:
        raw = base64.b64decode(public_key_b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise PublicKeyInvalid() from exc
    if len(raw) != _X963_LENGTH or raw[0] != 0x04:
        raise PublicKeyInvalid()
    try:
        return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)
    except ValueError as exc:
        raise PublicKeyInvalid() from exc


def verify_signature(public_key_b64: str, message: str, signature_b64: str) -> bool:
    """True only when `signature_b64` is a valid DER ECDSA-SHA256 signature of `message`."""
    try:
        key = load_public_key(public_key_b64)
        signature = base64.b64decode(signature_b64, validate=True)
    except (PublicKeyInvalid, binascii.Error, ValueError):
        return False
    if not signature:
        return False
    try:
        key.verify(signature, message.encode("utf-8"), ec.ECDSA(hashes.SHA256()))
    except (_CryptoInvalidSignature, ValueError):
        return False
    return True


def keyed_hash(key: bytes, value: str) -> str:
    """HMAC-SHA256 hex: how one-time codes and nonces are stored (never in the clear)."""
    return hmac.new(key, value.encode("utf-8"), sha256).hexdigest()


# ---------------------------------------------------------------- AES-256-GCM


class FieldCipher:
    """Authenticated encryption for sensitive columns. Token format: ``v1.<base64url(nonce|ct|tag)>``.

    `aad` binds a ciphertext to its row (for example ``provider|account``) so it cannot be moved.
    """

    def __init__(self, key: bytes) -> None:
        if len(key) != 32:
            raise ValueError("FieldCipher needs a 32-byte key")
        self._aead = AESGCM(key)

    def encrypt(self, plaintext: str | bytes, *, aad: str = "") -> str:
        data = plaintext.encode("utf-8") if isinstance(plaintext, str) else plaintext
        nonce = os.urandom(_NONCE_BYTES)
        sealed = self._aead.encrypt(nonce, data, aad.encode("utf-8"))
        return _CIPHER_PREFIX + base64.urlsafe_b64encode(nonce + sealed).decode("ascii")

    def decrypt(self, token: str, *, aad: str = "") -> bytes:
        if not token.startswith(_CIPHER_PREFIX):
            raise DecryptionFailed()
        try:
            raw = base64.urlsafe_b64decode(token[len(_CIPHER_PREFIX) :].encode("ascii"))
            if len(raw) <= _NONCE_BYTES:
                raise DecryptionFailed()
            return self._aead.decrypt(raw[:_NONCE_BYTES], raw[_NONCE_BYTES:], aad.encode("utf-8"))
        except (InvalidTag, binascii.Error, ValueError) as exc:
            raise DecryptionFailed() from exc

    def decrypt_str(self, token: str, *, aad: str = "") -> str:
        return self.decrypt(token, aad=aad).decode("utf-8")
