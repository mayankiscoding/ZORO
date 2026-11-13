"""Policy engine: allow | approval(level) | deny(reason), from static tool metadata and turn flags.

Order (design spec section 4): kill switch -> device not revoked -> agent on the tool's allowlist
-> permission grant -> rate limit -> risk rule. Nothing a model produces is an input here: `tool`
is the registered `ToolSpec`, and the turn flags are set by the orchestrator.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Literal, Protocol

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from app.core.types import AgentId, ApprovalLevel, RiskLevel

if TYPE_CHECKING:
    from app.security.devices import DeviceRegistry
    from app.security.permissions import PermissionService
    from app.security.state import KillSwitch
    from app.tools.spec import ToolSpec

log = logging.getLogger(__name__)

# ---------------------------------------------------------------- configuration (config/policy.yaml)


class PolicyToggles(BaseModel):
    model_config = ConfigDict(extra="ignore")

    strict_allow_public_external: bool = False
    biometric_for_high_risk: bool = False


class ApprovalTimings(BaseModel):
    model_config = ConfigDict(extra="ignore")

    default_expiry_seconds: int = Field(default=300, ge=30, le=3600)
    critical_expiry_seconds: int = Field(default=120, ge=30, le=120)  # spec: 2-minute ceiling


class PolicyConfig(BaseModel):
    model_config = ConfigDict(extra="ignore")

    version: int = 1
    toggles: PolicyToggles = Field(default_factory=PolicyToggles)
    approvals: ApprovalTimings = Field(default_factory=ApprovalTimings)


def load_policy_config(path: Path) -> PolicyConfig:
    """Read `policy.yaml`. A missing or malformed file yields the safe defaults (everything off)."""
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        return PolicyConfig.model_validate(raw)
    except FileNotFoundError:
        log.warning("policy.yaml not found; using safe defaults")
    except (OSError, yaml.YAMLError, ValidationError):
        log.error("policy.yaml is not valid; using safe defaults")
    return PolicyConfig()


class PolicyConfigSource:
    """Reloads `policy.yaml` when its modification time changes (no restart, no app rebuild)."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._mtime: float | None = None
        self._config = PolicyConfig()
        self._loaded = False

    def current(self) -> PolicyConfig:
        try:
            mtime: float | None = self._path.stat().st_mtime
        except OSError:
            mtime = None
        if not self._loaded or mtime != self._mtime:
            self._config = load_policy_config(self._path)
            self._mtime = mtime
            self._loaded = True
        return self._config


# ---------------------------------------------------------------- decision


@dataclass(frozen=True)
class PolicyDecision:
    kind: Literal["allow", "approval", "deny"]
    level: ApprovalLevel = ApprovalLevel.NONE
    reason: str = ""
    expires_in_seconds: int | None = None  # for approvals

    @property
    def allowed(self) -> bool:
        return self.kind == "allow"

    @property
    def needs_approval(self) -> bool:
        return self.kind == "approval"

    @property
    def denied(self) -> bool:
        return self.kind == "deny"


def allow(reason: str = "allowed") -> PolicyDecision:
    return PolicyDecision("allow", ApprovalLevel.NONE, reason)


def deny(reason: str) -> PolicyDecision:
    return PolicyDecision("deny", ApprovalLevel.NONE, reason)


def approval(level: ApprovalLevel, reason: str, expires_in_seconds: int) -> PolicyDecision:
    return PolicyDecision("approval", level, reason, expires_in_seconds)


class PolicySubject(Protocol):
    """The turn facts policy may look at. `ToolContext` satisfies this."""

    @property
    def agent(self) -> AgentId: ...
    @property
    def device_id(self) -> str | None: ...
    @property
    def tainted(self) -> bool: ...
    @property
    def user_initiated(self) -> bool: ...


class RateLimiter(Protocol):
    def allow(self, key: str, per_minute: int) -> bool: ...


def risk_rule(
    risk: RiskLevel, *, user_initiated: bool, tainted: bool, config: PolicyConfig
) -> PolicyDecision:
    """The risk table, as a pure function.

    | LOW      | allow                                                                    |
    | MEDIUM   | allow when the owner asked in this turn and it is not tainted; else confirm |
    | HIGH     | confirm; biometric when tainted or "Face ID for high-risk" is on         |
    | CRITICAL | always biometric, 2-minute expiry                                        |
    """
    timings = config.approvals
    if risk is RiskLevel.LOW:
        return allow("low_risk")
    if risk is RiskLevel.MEDIUM:
        if user_initiated and not tainted:
            return allow("medium_user_initiated")
        reason = "medium_tainted" if tainted else "medium_not_user_initiated"
        return approval(ApprovalLevel.CONFIRM, reason, timings.default_expiry_seconds)
    if risk is RiskLevel.HIGH:
        if tainted:
            return approval(ApprovalLevel.BIOMETRIC, "high_tainted", timings.default_expiry_seconds)
        if config.toggles.biometric_for_high_risk:
            return approval(ApprovalLevel.BIOMETRIC, "high_biometric_setting", timings.default_expiry_seconds)
        return approval(ApprovalLevel.CONFIRM, "high_risk", timings.default_expiry_seconds)
    return approval(ApprovalLevel.BIOMETRIC, "critical_risk", min(timings.critical_expiry_seconds, 120))


class PolicyEngine:
    def __init__(
        self,
        *,
        kill_switch: KillSwitch,
        devices: DeviceRegistry,
        permissions: PermissionService,
        rate_limiter: RateLimiter,
        config: Callable[[], PolicyConfig] | None = None,
    ) -> None:
        self._kill_switch = kill_switch
        self._devices = devices
        self._permissions = permissions
        self._rate_limiter = rate_limiter
        self._config = config or PolicyConfig

    @property
    def config(self) -> PolicyConfig:
        return self._config()

    async def gate(self, tool: ToolSpec, ctx: PolicySubject) -> PolicyDecision:
        """The hard gates only (kill switch, device, allowlist, permission). Re-run before a
        suspended call resumes, because any of them may have changed while it waited."""
        if await self._kill_switch.is_on():
            return deny("kill_switch")
        if ctx.device_id is not None:
            device = await self._devices.get(ctx.device_id)
            if device is None:
                return deny("device_unknown")
            if device.revoked:
                return deny("device_revoked")
        if ctx.agent not in tool.agents:
            return deny("agent_not_allowed")
        if tool.permission is not None and not await self._permissions.is_granted(tool.permission):
            return deny(f"permission_not_granted:{tool.permission}")
        return allow("gates_passed")

    async def evaluate(self, tool: ToolSpec, ctx: PolicySubject) -> PolicyDecision:
        gate = await self.gate(tool, ctx)
        if gate.denied:
            return gate
        bucket = f"{ctx.device_id or 'system'}:{tool.name}"
        if not self._rate_limiter.allow(bucket, tool.rate_limit_per_min):
            return deny("rate_limited")
        return risk_rule(
            tool.risk, user_initiated=ctx.user_initiated, tainted=ctx.tainted, config=self._config()
        )
