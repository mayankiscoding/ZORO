"""Policy engine: every gate in order, every risk rule, taint escalation, toggles from YAML."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import pytest

from app.core.types import AgentId, ApprovalLevel, RiskLevel
from app.plugins import PluginRegistry
from app.security.policy import (
    PolicyConfig,
    PolicyConfigSource,
    PolicyEngine,
    PolicyToggles,
    load_policy_config,
    risk_rule,
)
from app.tools.ratelimit import TokenBucketRateLimiter
from tests.conftest import PairedDevice
from tests.kernel.conftest import make_tool


@dataclass
class Turn:
    agent: AgentId = AgentId.PERSONAL_ASSISTANT
    device_id: str | None = None
    tainted: bool = False
    user_initiated: bool = True


DEFAULT = PolicyConfig()
FACE_ID = PolicyConfig(toggles=PolicyToggles(biometric_for_high_risk=True))

# ---------------------------------------------------------------- the risk table


@pytest.mark.parametrize("user_initiated", [True, False])
@pytest.mark.parametrize("tainted", [True, False])
@pytest.mark.parametrize("config", [DEFAULT, FACE_ID])
def test_low_risk_is_always_allowed(user_initiated: bool, tainted: bool, config: PolicyConfig) -> None:
    decision = risk_rule(RiskLevel.LOW, user_initiated=user_initiated, tainted=tainted, config=config)
    assert decision.allowed
    assert decision.level is ApprovalLevel.NONE


def test_medium_allowed_only_when_owner_asked_and_turn_is_clean() -> None:
    assert risk_rule(RiskLevel.MEDIUM, user_initiated=True, tainted=False, config=DEFAULT).allowed
    for user_initiated, tainted in [(False, False), (True, True), (False, True)]:
        decision = risk_rule(RiskLevel.MEDIUM, user_initiated=user_initiated, tainted=tainted, config=DEFAULT)
        assert decision.needs_approval
        assert decision.level is ApprovalLevel.CONFIRM
        assert decision.expires_in_seconds == 300


def test_high_needs_confirm_and_biometric_when_tainted_or_setting_on() -> None:
    for user_initiated in (True, False):
        clean = risk_rule(RiskLevel.HIGH, user_initiated=user_initiated, tainted=False, config=DEFAULT)
        assert clean.needs_approval and clean.level is ApprovalLevel.CONFIRM
        tainted = risk_rule(RiskLevel.HIGH, user_initiated=user_initiated, tainted=True, config=DEFAULT)
        assert tainted.needs_approval and tainted.level is ApprovalLevel.BIOMETRIC
        setting = risk_rule(RiskLevel.HIGH, user_initiated=user_initiated, tainted=False, config=FACE_ID)
        assert setting.needs_approval and setting.level is ApprovalLevel.BIOMETRIC


@pytest.mark.parametrize("user_initiated", [True, False])
@pytest.mark.parametrize("tainted", [True, False])
@pytest.mark.parametrize("config", [DEFAULT, FACE_ID])
def test_critical_is_always_biometric_with_two_minute_expiry(
    user_initiated: bool, tainted: bool, config: PolicyConfig
) -> None:
    decision = risk_rule(RiskLevel.CRITICAL, user_initiated=user_initiated, tainted=tainted, config=config)
    assert decision.needs_approval
    assert decision.level is ApprovalLevel.BIOMETRIC
    assert decision.expires_in_seconds == 120


def test_taint_never_lowers_and_raises_one_step() -> None:
    order = {ApprovalLevel.NONE: 0, ApprovalLevel.CONFIRM: 1, ApprovalLevel.BIOMETRIC: 2}
    for risk in RiskLevel:
        for user_initiated in (True, False):
            clean = risk_rule(risk, user_initiated=user_initiated, tainted=False, config=DEFAULT)
            dirty = risk_rule(risk, user_initiated=user_initiated, tainted=True, config=DEFAULT)
            assert order[dirty.level] >= order[clean.level]
    # the escalations the table names: MEDIUM none -> confirm, HIGH confirm -> biometric
    assert (
        risk_rule(RiskLevel.MEDIUM, user_initiated=True, tainted=True, config=DEFAULT).level
        is ApprovalLevel.CONFIRM
    )
    assert (
        risk_rule(RiskLevel.HIGH, user_initiated=True, tainted=True, config=DEFAULT).level
        is ApprovalLevel.BIOMETRIC
    )


# ---------------------------------------------------------------- gates, in order


async def test_gates_run_in_spec_order(registry: PluginRegistry, paired_device: PairedDevice) -> None:
    policy: PolicyEngine = registry.service("policy")
    registry.add_permission("test.write", "Write test things", False)
    tool = make_tool("test.write_thing", risk=RiskLevel.LOW, permission="test.write", rate_limit_per_min=2)
    turn = Turn(device_id=paired_device.device_id)

    # permission grant
    assert (await policy.evaluate(tool, turn)).reason == "permission_not_granted:test.write"
    await registry.service("permissions").set("test.write", True)
    assert (await policy.evaluate(tool, turn)).allowed

    # agent allowlist comes before the permission check
    await registry.service("permissions").set("test.write", False)
    stranger = Turn(agent=AgentId.SHOPPING, device_id=paired_device.device_id)
    assert (await policy.evaluate(tool, stranger)).reason == "agent_not_allowed"

    # device check comes before the allowlist
    assert (
        await policy.evaluate(tool, Turn(agent=AgentId.SHOPPING, device_id="dev_missing"))
    ).reason == "device_unknown"
    await registry.service("devices").revoke(paired_device.device_id)
    assert (await policy.evaluate(tool, stranger)).reason == "device_revoked"

    # kill switch comes before everything
    await registry.service("kill_switch").set(True)
    decision = await policy.evaluate(tool, stranger)
    assert decision.denied and decision.reason == "kill_switch"
    assert (await policy.evaluate(make_tool(), Turn())).reason == "kill_switch"
    await registry.service("kill_switch").set(False)
    assert (await policy.evaluate(make_tool(), Turn())).allowed


async def test_rate_limit_comes_after_permission_and_before_risk(registry: PluginRegistry) -> None:
    policy: PolicyEngine = registry.service("policy")
    tool = make_tool("test.send_thing", risk=RiskLevel.HIGH, rate_limit_per_min=2)
    turn = Turn()
    assert (await policy.evaluate(tool, turn)).needs_approval
    assert (await policy.evaluate(tool, turn)).needs_approval
    limited = await policy.evaluate(tool, turn)
    assert limited.denied and limited.reason == "rate_limited"
    # a denied gate does not spend rate-limit tokens
    other = make_tool("test.other_thing", rate_limit_per_min=1)
    for _ in range(3):
        assert (await policy.evaluate(other, Turn(agent=AgentId.MUSIC))).reason == "agent_not_allowed"
    assert (await policy.evaluate(other, turn)).allowed
    # `gate` (used on resume) never spends tokens either
    for _ in range(5):
        assert (await policy.gate(other, turn)).allowed


async def test_undeclared_permission_is_never_granted(registry: PluginRegistry) -> None:
    policy: PolicyEngine = registry.service("policy")
    tool = make_tool("test.ghost", permission="ghost.permission")
    assert (await policy.evaluate(tool, Turn())).reason == "permission_not_granted:ghost.permission"


async def test_system_turn_without_a_device_follows_the_risk_rules(registry: PluginRegistry) -> None:
    policy: PolicyEngine = registry.service("policy")
    medium = make_tool("test.remind", risk=RiskLevel.MEDIUM)
    background = Turn(device_id=None, user_initiated=False)
    decision = await policy.evaluate(medium, background)
    assert decision.needs_approval and decision.level is ApprovalLevel.CONFIRM


# ---------------------------------------------------------------- toggles from config/policy.yaml


def test_shipped_policy_yaml_has_everything_off() -> None:
    shipped = Path(__file__).resolve().parents[3] / "config" / "policy.yaml"
    config = load_policy_config(shipped)
    assert config.toggles.strict_allow_public_external is False
    assert config.toggles.biometric_for_high_risk is False
    assert config.approvals.default_expiry_seconds == 300
    assert config.approvals.critical_expiry_seconds == 120


def test_policy_config_reloads_and_fails_safe(tmp_path: Path) -> None:
    path = tmp_path / "policy.yaml"
    source = PolicyConfigSource(path)
    assert source.current() == PolicyConfig()  # missing file: safe defaults

    path.write_text("toggles:\n  biometric_for_high_risk: true\n  strict_allow_public_external: true\n")
    os.utime(path, (1_000_000, 1_000_000))
    assert source.current().toggles.biometric_for_high_risk is True
    assert source.current().toggles.strict_allow_public_external is True

    path.write_text("toggles: [not, a, mapping")  # malformed: back to safe defaults
    os.utime(path, (2_000_000, 2_000_000))
    assert source.current() == PolicyConfig()

    path.write_text("approvals:\n  critical_expiry_seconds: 600\n")  # cannot exceed two minutes
    os.utime(path, (3_000_000, 3_000_000))
    assert source.current().approvals.critical_expiry_seconds == 120


async def test_engine_reads_the_face_id_toggle(registry: PluginRegistry) -> None:
    engine = PolicyEngine(
        kill_switch=registry.service("kill_switch"),
        devices=registry.service("devices"),
        permissions=registry.service("permissions"),
        rate_limiter=TokenBucketRateLimiter(),
        config=lambda: FACE_ID,
    )
    decision = await engine.evaluate(make_tool("test.send_mail", risk=RiskLevel.HIGH), Turn())
    assert decision.level is ApprovalLevel.BIOMETRIC
    default = await registry.service("policy").evaluate(
        make_tool("test.send_mail", risk=RiskLevel.HIGH), Turn()
    )
    assert default.level is ApprovalLevel.CONFIRM


def test_token_bucket_refills_over_time() -> None:
    now = [0.0]
    limiter = TokenBucketRateLimiter(time_fn=lambda: now[0])
    assert [limiter.allow("k", 3) for _ in range(4)] == [True, True, True, False]
    now[0] += 20.0  # one token per 20 s at 3 per minute
    assert limiter.allow("k", 3) is True
    assert limiter.allow("k", 3) is False
    assert limiter.allow("other", 3) is True  # keys are independent
    now[0] += 3600.0
    assert [limiter.allow("k", 3) for _ in range(4)] == [True, True, True, False]  # capped at capacity
    assert limiter.allow("k", 0) is False
    limiter.reset("k")
    assert limiter.allow("k", 3) is True
