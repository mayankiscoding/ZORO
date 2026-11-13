"""ApprovalService: digest, happy path, wrong key, wrong digest, expiry, replay, pending list."""

from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import FixedClock
from app.core.errors import (
    ApprovalDigestMismatch,
    ApprovalExpired,
    ApprovalNotFound,
    ApprovalReplayed,
    InvalidSignature,
)
from app.core.ids import canonical_json, sha256_hex
from app.core.types import AgentId, ApprovalLevel, RiskLevel
from app.plugins import PluginRegistry
from app.schemas.common import LabelValue
from app.schemas.turns import ApprovalRequest
from app.security.approvals import ApprovalService, action_digest
from app.security.models import ApprovalRow
from tests.conftest import PairDevice, PairedDevice

ARGS = {"to": "hr@example.com", "subject": "Leave", "body": "I will be away on Friday."}


async def _create(
    registry: PluginRegistry,
    *,
    level: ApprovalLevel = ApprovalLevel.CONFIRM,
    risk: RiskLevel = RiskLevel.HIGH,
    args: dict[str, str] | None = None,
) -> ApprovalRequest:
    approvals: ApprovalService = registry.service("approvals")
    return await approvals.create(
        tool="communications.send_email",
        args=args or ARGS,
        risk=risk,
        level=level,
        title="Send email to hr@example.com",
        summary="Leave: I will be away on Friday.",
        details=[LabelValue(label="To", value="hr@example.com")],
        turn_id="turn_1",
        agent=AgentId.COMMUNICATION,
        call_id="call_1",
    )


def test_digest_is_canonical_and_binds_tool_and_args() -> None:
    digest = action_digest("communications.send_email", ARGS)
    assert digest == sha256_hex(canonical_json({"tool": "communications.send_email", "args": ARGS}))
    assert digest == action_digest("communications.send_email", dict(reversed(list(ARGS.items()))))
    assert digest != action_digest("communications.send_email", {**ARGS, "to": "attacker@example.com"})
    assert digest != action_digest("communications.draft_email", ARGS)
    assert len(digest) == 64


async def test_happy_path_confirm_with_auth_key(
    registry: PluginRegistry, paired_device: PairedDevice
) -> None:
    approvals: ApprovalService = registry.service("approvals")
    request = await _create(registry)
    assert request.level is ApprovalLevel.CONFIRM
    assert request.action_digest == action_digest("communications.send_email", ARGS)
    assert [r.approval_id for r in await approvals.list_pending()] == [request.approval_id]
    assert await approvals.get(request.approval_id) == request

    verdict = await approvals.verify(paired_device.signer.sign_approval(request, approved=True))
    assert verdict.approved is True
    assert verdict.tool == "communications.send_email"
    assert verdict.action_digest == request.action_digest
    assert verdict.call_id == "call_1"
    assert verdict.device_id == paired_device.device_id
    assert await approvals.status(request.approval_id) == "approved"
    assert await approvals.list_pending() == []


async def test_happy_path_biometric_and_signed_denial(
    registry: PluginRegistry, paired_device: PairedDevice
) -> None:
    approvals: ApprovalService = registry.service("approvals")
    request = await _create(registry, level=ApprovalLevel.BIOMETRIC)
    verdict = await approvals.verify(paired_device.signer.sign_approval(request, approved=True))
    assert verdict.approved and verdict.level is ApprovalLevel.BIOMETRIC

    second = await _create(registry)
    denial = await approvals.verify(paired_device.signer.sign_approval(second, approved=False))
    assert denial.approved is False
    assert await approvals.status(second.approval_id) == "denied"


async def test_wrong_key_for_the_level_is_rejected(
    registry: PluginRegistry, paired_device: PairedDevice
) -> None:
    approvals: ApprovalService = registry.service("approvals")
    biometric = await _create(registry, level=ApprovalLevel.BIOMETRIC)
    with pytest.raises(InvalidSignature):  # a tap (auth key) cannot stand in for Face ID
        await approvals.verify(paired_device.signer.sign_approval(biometric, key="auth"))
    confirm = await _create(registry, level=ApprovalLevel.CONFIRM)
    with pytest.raises(InvalidSignature):
        await approvals.verify(paired_device.signer.sign_approval(confirm, key="approval"))
    # a failed check does not burn the request: the right key still works
    assert await approvals.status(biometric.approval_id) == "pending"
    assert (await approvals.verify(paired_device.signer.sign_approval(biometric))).approved


async def test_signature_from_another_device_or_flipped_decision_is_rejected(
    registry: PluginRegistry, paired_device: PairedDevice, pair_device: PairDevice
) -> None:
    approvals: ApprovalService = registry.service("approvals")
    request = await _create(registry)
    other = await pair_device(name="Other phone")

    forged = other.signer.sign_approval(request).model_copy(update={"device_id": paired_device.device_id})
    with pytest.raises(InvalidSignature):
        await approvals.verify(forged)

    denial = paired_device.signer.sign_approval(request, approved=False)
    with pytest.raises(InvalidSignature):  # "no" cannot be turned into "yes"
        await approvals.verify(denial.model_copy(update={"approved": True}))

    await registry.service("devices").revoke(other.device_id)
    with pytest.raises(InvalidSignature):
        await approvals.verify(other.signer.sign_approval(request))
    with pytest.raises(InvalidSignature):
        await approvals.verify(
            paired_device.signer.sign_approval(request).model_copy(update={"device_id": "dev_x"})
        )
    assert await approvals.status(request.approval_id) == "pending"


async def test_wrong_digest_is_rejected(registry: PluginRegistry, paired_device: PairedDevice) -> None:
    approvals: ApprovalService = registry.service("approvals")
    request = await _create(registry)
    other_digest = action_digest("communications.send_email", {**ARGS, "to": "attacker@example.com"})
    with pytest.raises(ApprovalDigestMismatch):
        await approvals.verify(paired_device.signer.sign_approval(request, action_digest=other_digest))
    # signing the right digest but presenting another one fails too
    good = paired_device.signer.sign_approval(request)
    with pytest.raises(ApprovalDigestMismatch):
        await approvals.verify(good.model_copy(update={"action_digest": other_digest}))
    assert await approvals.status(request.approval_id) == "pending"


async def test_expired_request_is_rejected(
    registry: PluginRegistry, paired_device: PairedDevice, clock: FixedClock
) -> None:
    approvals: ApprovalService = registry.service("approvals")
    request = await _create(registry)
    assert request.expires_at == clock.now() + timedelta(seconds=300)
    decision = paired_device.signer.sign_approval(request)
    clock.advance(301)
    assert await approvals.list_pending() == []
    assert await approvals.status(request.approval_id) == "expired"
    with pytest.raises(ApprovalExpired):
        await approvals.verify(decision)
    with pytest.raises(ApprovalReplayed):  # now marked expired for good
        await approvals.verify(paired_device.signer.sign_approval(request))


async def test_critical_requests_are_biometric_and_expire_in_two_minutes(
    registry: PluginRegistry, paired_device: PairedDevice, clock: FixedClock
) -> None:
    approvals: ApprovalService = registry.service("approvals")
    request = await approvals.create(
        tool="memory.export_all", args={}, risk=RiskLevel.CRITICAL, level=ApprovalLevel.CONFIRM,
        title="Export all memories", summary="Everything ZORO remembers", expires_in_seconds=900,
    )  # fmt: skip
    assert request.level is ApprovalLevel.BIOMETRIC
    assert request.expires_at == clock.now() + timedelta(seconds=120)
    clock.advance(121)
    with pytest.raises(ApprovalExpired):
        await approvals.verify(paired_device.signer.sign_approval(request))
    with pytest.raises(ValueError):
        await approvals.create(
            tool="x.y", args={}, risk=RiskLevel.HIGH, level=ApprovalLevel.NONE, title="t", summary="s"
        )


async def test_replay_is_rejected(registry: PluginRegistry, paired_device: PairedDevice) -> None:
    approvals: ApprovalService = registry.service("approvals")
    request = await _create(registry)
    decision = paired_device.signer.sign_approval(request)
    assert (await approvals.verify(decision)).approved
    with pytest.raises(ApprovalReplayed):
        await approvals.verify(decision)
    with pytest.raises(ApprovalReplayed):
        await approvals.verify(paired_device.signer.sign_approval(request, approved=False))
    with pytest.raises(ApprovalNotFound):
        await approvals.verify(decision.model_copy(update={"approval_id": "apr_missing"}))


async def test_decision_signed_outside_the_request_lifetime_is_rejected(
    registry: PluginRegistry, paired_device: PairedDevice, clock: FixedClock
) -> None:
    approvals: ApprovalService = registry.service("approvals")
    request = await _create(registry)
    early = paired_device.signer.sign_approval(request, signed_at=clock.now() - timedelta(minutes=10))
    with pytest.raises(InvalidSignature):
        await approvals.verify(early)
    late = paired_device.signer.sign_approval(request, signed_at=clock.now() + timedelta(minutes=10))
    with pytest.raises(InvalidSignature):
        await approvals.verify(late)


async def test_what_the_owner_sees_is_encrypted_at_rest(registry: PluginRegistry, db: AsyncSession) -> None:
    request = await _create(registry)
    row = (await db.execute(select(ApprovalRow).where(ApprovalRow.id == request.approval_id))).scalar_one()
    assert row.presentation_enc.startswith("v1.")
    assert "hr@example.com" not in row.presentation_enc
    assert row.action_digest == request.action_digest
    assert row.status == "pending"
