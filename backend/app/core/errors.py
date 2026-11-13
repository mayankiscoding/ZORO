"""Error hierarchy. Every `ZoroError` maps to `schemas.common.ErrorBody` with a stable `code`."""

from __future__ import annotations

from typing import Any, ClassVar

from app.schemas.common import ErrorBody


class ZoroError(Exception):
    code: ClassVar[str] = "internal_error"
    status: ClassVar[int] = 500
    retryable: ClassVar[bool] = False
    default_message: ClassVar[str] = "Something went wrong on the ZORO server."

    def __init__(
        self,
        message: str | None = None,
        *,
        detail: dict[str, Any] | None = None,
        code: str | None = None,
    ) -> None:
        self.message = message or self.default_message
        self.detail = detail
        self.error_code = code or self.code
        super().__init__(self.message)

    def to_body(self) -> ErrorBody:
        return ErrorBody(
            code=self.error_code, message=self.message, retryable=self.retryable, detail=self.detail
        )


# ---------------------------------------------------------------- generic


class BadRequest(ZoroError):
    code = "bad_request"
    status = 400
    default_message = "The request is not valid."


class ValidationFailed(ZoroError):
    code = "validation_error"
    status = 422
    default_message = "The request body or parameters are not valid."


class Unauthorized(ZoroError):
    code = "unauthorized"
    status = 401
    default_message = "Sign in again from a paired device."


class Forbidden(ZoroError):
    code = "forbidden"
    status = 403
    default_message = "This action is not allowed."


class NotFound(ZoroError):
    code = "not_found"
    status = 404
    default_message = "Not found."


class Conflict(ZoroError):
    code = "conflict"
    status = 409
    default_message = "The request conflicts with the current state."


class RateLimited(ZoroError):
    code = "rate_limited"
    status = 429
    retryable = True
    default_message = "Too many requests. Try again in a moment."


class Unavailable(ZoroError):
    """A source or integration cannot answer right now (never substitute invented data)."""

    code = "unavailable"
    status = 503
    retryable = True
    default_message = "This is unavailable right now."


class ConfigError(ZoroError):
    code = "config_error"
    status = 500
    default_message = "The server configuration is not valid."


class KillSwitchActive(ZoroError):
    code = "kill_switch_active"
    status = 503
    default_message = "The kill switch is on. Turn it off in Security and privacy to continue."


# ---------------------------------------------------------------- devices and sessions


class PairingCodeInvalid(BadRequest):
    code = "pairing_code_invalid"
    default_message = "The pairing code is wrong, already used or expired. Create a new one on the server."


class PublicKeyInvalid(BadRequest):
    code = "public_key_invalid"
    default_message = "The device key is not a valid P-256 public key."


class DeviceNotFound(NotFound):
    code = "device_not_found"
    default_message = "This device is not paired with the server."


class DeviceRevoked(Forbidden):
    code = "device_revoked"
    default_message = "This device was revoked. Pair it again to continue."


class ChallengeInvalid(Unauthorized):
    code = "challenge_invalid"
    default_message = "The sign-in challenge is unknown, already used or expired."


class InvalidSignature(Unauthorized):
    code = "invalid_signature"
    default_message = "The signature does not match the registered device key."


class TokenInvalid(Unauthorized):
    code = "token_invalid"
    default_message = "The session is missing, expired or revoked. Sign in again."


# ---------------------------------------------------------------- signed proofs and approvals


class ProofInvalid(Forbidden):
    code = "proof_invalid"
    default_message = "The signed proof is not valid for this action."


class ProofStale(Forbidden):
    code = "proof_stale"
    default_message = "The signed proof is too old or from the future. Check the device clock and retry."


class ProofReplayed(Conflict):
    code = "proof_replayed"
    default_message = "This signed proof was already used."


class ApprovalNotFound(NotFound):
    code = "approval_not_found"
    default_message = "This approval request does not exist."


class ApprovalExpired(ZoroError):
    code = "approval_expired"
    status = 410
    default_message = "This approval request expired. Ask again to get a new one."


class ApprovalReplayed(Conflict):
    code = "approval_replayed"
    default_message = "This approval request was already answered."


class ApprovalDigestMismatch(Conflict):
    code = "approval_digest_mismatch"
    default_message = "The approved action does not match the action the server prepared."


class PermissionUnknown(NotFound):
    code = "permission_unknown"
    default_message = "No feature declares this permission."


class DecryptionFailed(ZoroError):
    code = "decryption_failed"
    status = 500
    default_message = "Stored data could not be decrypted with the configured data key."
