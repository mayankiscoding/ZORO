"""Kernel security tables: devices, sessions, grants, approvals, audit chain, encrypted credentials."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import BigInteger, Boolean, Index, Integer, String, Text, UniqueConstraint, event
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, UTCDateTime, utcnow
from app.db.types import JSONType


class Device(Base, TimestampMixin):
    __tablename__ = "devices"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    platform: Mapped[str] = mapped_column(String(16))
    auth_public_key_b64: Mapped[str] = mapped_column(String(200))
    approval_public_key_b64: Mapped[str] = mapped_column(String(200))
    capabilities: Mapped[list[str]] = mapped_column(JSONType, default=list)
    app_version: Mapped[str | None] = mapped_column(String(64), nullable=True)
    last_seen_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


class PairingCode(Base):
    __tablename__ = "pairing_codes"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    code_hash: Mapped[str] = mapped_column(String(64), unique=True)  # HMAC-SHA256, never the code
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime)
    used_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    used_by_device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class AuthChallenge(Base):
    __tablename__ = "auth_challenges"

    nonce_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    device_id: Mapped[str] = mapped_column(String(64), index=True)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime)
    used_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


class DeviceSession(Base):
    __tablename__ = "device_sessions"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)  # the JWT `sid`
    device_id: Mapped[str] = mapped_column(String(64), index=True)
    issued_at: Mapped[datetime] = mapped_column(UTCDateTime)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


class UsedProof(Base):
    """One row per accepted `SignedProof`, keyed by a digest of what was signed (replay guard)."""

    __tablename__ = "used_proofs"

    digest: Mapped[str] = mapped_column(String(64), primary_key=True)
    device_id: Mapped[str] = mapped_column(String(64))
    signed_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)


class PermissionGrantRow(Base):
    __tablename__ = "permission_grants"

    key: Mapped[str] = mapped_column(String(100), primary_key=True)
    granted: Mapped[bool] = mapped_column(Boolean)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    updated_by: Mapped[str | None] = mapped_column(String(64), nullable=True)


class SecuritySetting(Base):
    __tablename__ = "security_settings"

    key: Mapped[str] = mapped_column(String(100), primary_key=True)
    value: Mapped[Any] = mapped_column(JSONType)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    updated_by: Mapped[str | None] = mapped_column(String(64), nullable=True)


class ApprovalRow(Base):
    __tablename__ = "approvals"
    __table_args__ = (Index("ix_approvals_status_expires", "status", "expires_at"),)

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    call_id: Mapped[str | None] = mapped_column(String(128), nullable=True, index=True)
    turn_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    tool: Mapped[str] = mapped_column(String(200))
    agent: Mapped[str | None] = mapped_column(String(64), nullable=True)
    risk: Mapped[str] = mapped_column(String(16))
    level: Mapped[str] = mapped_column(String(16))
    presentation_enc: Mapped[str] = mapped_column(Text)  # title, summary, details (may be sensitive)
    action_digest: Mapped[str] = mapped_column(String(64))
    requested_by_device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    status: Mapped[str] = mapped_column(String(16), default="pending")  # pending|approved|denied|expired
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime)
    decided_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    decided_by_device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class AuditRow(Base):
    """Append-only. `hash = sha256(prev_hash + canonical record)`; `prev_hash` is unique so the
    chain cannot fork."""

    __tablename__ = "audit_log"

    seq: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), primary_key=True, autoincrement=True
    )
    id: Mapped[str] = mapped_column(String(64), unique=True)
    ts: Mapped[datetime] = mapped_column(UTCDateTime)
    actor: Mapped[str] = mapped_column(String(100))
    action: Mapped[str] = mapped_column(String(100), index=True)
    tool: Mapped[str | None] = mapped_column(String(200), nullable=True)
    risk: Mapped[str | None] = mapped_column(String(16), nullable=True)
    decision: Mapped[str] = mapped_column(String(16))
    data_classes: Mapped[list[str]] = mapped_column(JSONType, default=list)
    detail: Mapped[str] = mapped_column(Text, default="")
    prev_hash: Mapped[str] = mapped_column(String(64), unique=True)
    hash: Mapped[str] = mapped_column(String(64), unique=True)


class IntegrationCredential(Base, TimestampMixin):
    """Integration tokens, encrypted with AES-256-GCM (`ZORO_DATA_KEY`) through `SecretStore`."""

    __tablename__ = "integration_credentials"
    __table_args__ = (UniqueConstraint("provider", "account"),)

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    provider: Mapped[str] = mapped_column(String(100))
    account: Mapped[str] = mapped_column(String(200), default="default")
    ciphertext: Mapped[str] = mapped_column(Text)
    expires_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


def _refuse_audit_change(_mapper: Any, _connection: Any, _target: Any) -> None:
    raise RuntimeError("audit_log is append-only")


event.listen(AuditRow, "before_update", _refuse_audit_change)
event.listen(AuditRow, "before_delete", _refuse_audit_change)
