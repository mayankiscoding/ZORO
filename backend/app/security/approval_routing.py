"""One way to answer any approval: route a signed `ApprovalDecision` to whoever owns the call.

Owners (a suspended conversation turn, an MCP call, an automation run) register a handler with
`ApprovalRouter.register`. `POST /v1/approvals/{approval_id}/decision` asks each owner in turn
whether the approval is theirs and hands the decision to the first that claims it. The router
never verifies or consumes the decision itself: the owner resumes its call through
`ToolExecutor.resume_with_approval`, which checks the signature, the digest, expiry and replay.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from app.core.errors import ApprovalNotFound, ApprovalReplayed, BadRequest, Conflict, Forbidden
from app.schemas.turns import ApprovalDecision, ApprovalDecisionResult
from app.security.approvals import ApprovalLookup, ApprovalService
from app.security.sessions import AuthedDevice

log = logging.getLogger(__name__)

Claims = Callable[[ApprovalLookup], Awaitable[bool]]
Decide = Callable[[ApprovalDecision, AuthedDevice, ApprovalLookup], Awaitable[ApprovalDecisionResult]]


@dataclass(frozen=True)
class ApprovalOwner:
    name: str  # "turn" | "mcp" | "automation" | ...
    claims: Claims
    decide: Decide


class ApprovalRouter:
    """Registered as service ``approval_router``."""

    def __init__(self, approvals: ApprovalService) -> None:
        self._approvals = approvals
        self._owners: list[ApprovalOwner] = []

    def register(self, name: str, claims: Claims, decide: Decide) -> None:
        if any(owner.name == name for owner in self._owners):
            raise ValueError(f"approval owner already registered: {name}")
        self._owners.append(ApprovalOwner(name, claims, decide))

    @property
    def owners(self) -> list[str]:
        return [owner.name for owner in self._owners]

    async def decide(
        self, approval_id: str, decision: ApprovalDecision, device: AuthedDevice
    ) -> ApprovalDecisionResult:
        if decision.approval_id != approval_id:
            raise BadRequest("The decision is for a different approval.", code="approval_mismatch")
        if decision.device_id != device.device_id:
            raise Forbidden("A device can only submit its own signed decisions.", code="wrong_device")
        lookup = await self._approvals.lookup(approval_id)
        if lookup is None:
            raise ApprovalNotFound()
        if lookup.status != "pending":
            # Answered, expired or withdrawn: nothing may run again from this request.
            raise ApprovalReplayed()
        for owner in self._owners:
            if await owner.claims(lookup):
                return await owner.decide(decision, device, lookup)
        raise Conflict(
            "Nothing is waiting for this approval any more.", code="approval_owner_not_found"
        )
