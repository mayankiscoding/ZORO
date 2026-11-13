"""Security, capability registry and cost contract."""

from __future__ import annotations

from decimal import Decimal
from typing import Literal

from pydantic import AwareDatetime, Field

from app.core.types import (
    CapabilityStatus,
    DataClass,
    IntegrationLevel,
    Locality,
    PrivacyMode,
    RiskLevel,
    TaskClass,
)
from app.schemas.auth import DeviceInfo
from app.schemas.common import SignedProof, ZModel


class PermissionGrant(ZModel):
    key: str  # e.g. "finance.read", "messages.send", "cloud.financial"
    title: str
    granted: bool
    updated_at: AwareDatetime | None = None


class SecurityState(ZModel):
    privacy_mode: PrivacyMode
    kill_switch: bool
    strict_allow_public_external: bool
    biometric_for_high_risk: bool
    session_expires_at: AwareDatetime
    permissions: list[PermissionGrant]
    devices: list[DeviceInfo]


class PrivacyModeUpdate(ZModel):
    """Signed subject: the mode value. Action name: ``set_privacy_mode``."""

    mode: PrivacyMode
    proof: SignedProof


class KillSwitchUpdate(ZModel):
    """Signed subject: ``true`` or ``false``. Action name: ``set_kill_switch``."""

    enabled: bool
    proof: SignedProof


class PermissionUpdate(ZModel):
    """Signed subject: ``{key}={true|false}``. Action name: ``set_permission``."""

    granted: bool
    proof: SignedProof


class DeviceRevoke(ZModel):
    """Signed subject: the device id being revoked. Action name: ``revoke_device``."""

    proof: SignedProof


class AuditRecord(ZModel):
    id: str
    ts: AwareDatetime
    actor: str  # device id, agent id or "system"
    action: str
    tool: str | None = None
    risk: RiskLevel | None = None
    decision: Literal["allowed", "approved", "denied", "blocked", "failed", "info"]
    data_classes: list[DataClass] = Field(default_factory=list)
    detail: str = ""  # never contains raw sensitive payloads
    prev_hash: str
    hash: str


class Capability(ZModel):
    id: str  # e.g. "ios.alarm.create", "shopping.zepto.search"
    title: str
    domain: str
    status: CapabilityStatus
    integration_level: IntegrationLevel | None = None
    requires: list[str] = Field(default_factory=list)  # env vars, entitlements, user steps
    note: str = ""


class CostRow(ZModel):
    key: str
    requests: int
    input_tokens: int
    output_tokens: int
    audio_seconds: float = 0
    avg_latency_ms: float = 0
    error_rate: float = 0
    cost_usd: Decimal = Decimal("0")


class CostSummary(ZModel):
    group_by: Literal["provider", "model", "task", "agent", "day"]
    total_cost_usd: Decimal
    items: list[CostRow]


class ModelRouteInfo(ZModel):
    task: TaskClass
    models: list[str]  # ordered model ids from config
    active_model: str | None  # first healthy + permitted one right now
    locality: Locality | None
    reason: str = ""
