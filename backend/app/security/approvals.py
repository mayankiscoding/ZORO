"""Approvals: the server prepares an action, a registered device signs the decision.

``action_digest = sha256(canonical {tool, args})``. The device signs
``zoro-approval-v1|{approval_id}|{action_digest}|{1 or 0}|{signed_at}`` with the approval
(user-presence) key for `biometric`, otherwise with the auth key. A request is answered at most
once; the executor then runs exactly the digested arguments.
"""

from __future__ import annotations

import inspect
import json
import logging
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from sqlalchemy import select, update

from app.core.clock import Clock, SystemClock
from app.core.errors import (
    ApprovalDigestMismatch,
    ApprovalExpired,
    ApprovalNotFound,
    ApprovalReplayed,
    DeviceNotFound,
    DeviceRevoked,
    InvalidSignature,
)
from app.core.ids import canonical_json, new_id, sha256_hex
from app.core.types import AgentId, ApprovalLevel, RiskLevel
from app.db.session import SessionFactory, affected_rows
from app.schemas.common import LabelValue
from app.schemas.turns import ApprovalDecision, ApprovalRequest
from app.security.crypto import FieldCipher, approval_message, verify_signature
from app.security.devices import DeviceRegistry
from app.security.models import ApprovalRow

log = logging.getLogger(__name__)

Announcer = Callable[[ApprovalRequest], Awaitable[Any] | Any]

SIGNATURE_SKEW_SECONDS = 120
CRITICAL_EXPIRY_SECONDS = 120
DEFAULT_EXPIRY_SECONDS = 300


def action_digest(tool: str, args: Mapping[str, Any]) -> str:
    """Hex SHA-256 over the canonical JSON of ``{"tool": tool, "args": args}`` (JSON-native args)."""
    return sha256_hex(canonical_json({"tool": tool, "args": dict(args)}))


@dataclass(frozen=True)
class ApprovalVerdict:
    approval_id: str
    approved: bool
    tool: str
    action_digest: str
    level: ApprovalLevel
    call_id: str | None
    turn_id: str | None
    device_id: str


@dataclass(frozen=True)
class ApprovalLookup:
    """Who an approval belongs to, without its (encrypted) presentation."""

    approval_id: str
    tool: str
    status: str  # pending | approved | denied | expired | cancelled
    call_id: str | None
    turn_id: str | None
    requested_by_device_id: str | None


class ApprovalService:
    def __init__(
        self,
        session_factory: SessionFactory,
        devices: DeviceRegistry,
        cipher: FieldCipher,
        clock: Clock | None = None,
    ) -> None:
        self._sf = session_factory
        self._devices = devices
        self._cipher = cipher
        self._clock = clock or SystemClock()
        self._announcers: list[Announcer] = []

    action_digest = staticmethod(action_digest)

    # ------------------------------------------------------------ announce

    def add_announcer(self, fn: Announcer) -> None:
        """`fn(request)` is called for approvals no live turn stream will show (MCP calls,
        automation runs). The devices package pushes them over the device channel."""
        self._announcers.append(fn)

    async def announce(self, request: ApprovalRequest) -> None:
        for fn in self._announcers:
            try:
                result = fn(request)
                if inspect.isawaitable(result):
                    await result
            except Exception as exc:  # telling a device is best effort; the request stays listed
                log.warning("approval announcement failed", extra={"error_type": type(exc).__name__})

    # ------------------------------------------------------------ create

    async def create(
        self,
        *,
        tool: str,
        args: Mapping[str, Any],
        risk: RiskLevel,
        level: ApprovalLevel,
        title: str,
        summary: str,
        details: Sequence[LabelValue] = (),
        turn_id: str | None = None,
        agent: AgentId | None = None,
        call_id: str | None = None,
        device_id: str | None = None,
        expires_in_seconds: int | None = None,
        tainted: bool = False,
    ) -> ApprovalRequest:
        if level is ApprovalLevel.NONE:
            raise ValueError("an approval request needs level confirm or biometric")
        if risk is RiskLevel.CRITICAL:
            level = ApprovalLevel.BIOMETRIC
            ttl = min(expires_in_seconds or CRITICAL_EXPIRY_SECONDS, CRITICAL_EXPIRY_SECONDS)
        else:
            ttl = expires_in_seconds or DEFAULT_EXPIRY_SECONDS
        now = self._clock.now()
        approval_id = new_id("apr")
        request = ApprovalRequest(
            approval_id=approval_id,
            turn_id=turn_id,
            tool=tool,
            agent=agent,
            risk=risk,
            level=level,
            title=title,
            summary=summary,
            details=list(details),
            action_digest=action_digest(tool, args),
            expires_at=now + timedelta(seconds=ttl),
            tainted=tainted,
        )
        presentation = json.dumps(
            {
                "title": title,
                "summary": summary,
                "details": [d.model_dump() for d in details],
                "tainted": tainted,
            },
            ensure_ascii=False,
        )
        async with self._sf() as session:
            session.add(
                ApprovalRow(
                    id=approval_id,
                    call_id=call_id,
                    turn_id=turn_id,
                    tool=tool,
                    agent=agent.value if agent is not None else None,
                    risk=risk.value,
                    level=level.value,
                    presentation_enc=self._cipher.encrypt(presentation, aad=approval_id),
                    action_digest=request.action_digest,
                    requested_by_device_id=device_id,
                    status="pending",
                    created_at=now,
                    expires_at=request.expires_at,
                )
            )
            await session.commit()
        return request

    # ------------------------------------------------------------ read

    def _to_request(self, row: ApprovalRow) -> ApprovalRequest:
        shown = json.loads(self._cipher.decrypt_str(row.presentation_enc, aad=row.id))
        return ApprovalRequest(
            approval_id=row.id,
            turn_id=row.turn_id,
            tool=row.tool,
            agent=AgentId(row.agent) if row.agent else None,
            risk=RiskLevel(row.risk),
            level=ApprovalLevel(row.level),
            title=shown["title"],
            summary=shown["summary"],
            details=[LabelValue(**item) for item in shown.get("details", [])],
            action_digest=row.action_digest,
            expires_at=row.expires_at,
            tainted=bool(shown.get("tainted", False)),
        )

    async def lookup(self, approval_id: str) -> ApprovalLookup | None:
        """Owner facts for routing a decision (call, turn, requesting device, status)."""
        async with self._sf() as session:
            row = await session.get(ApprovalRow, approval_id)
        if row is None:
            return None
        expired = row.status == "pending" and row.expires_at <= self._clock.now()
        return ApprovalLookup(
            approval_id=row.id,
            tool=row.tool,
            status="expired" if expired else row.status,
            call_id=row.call_id,
            turn_id=row.turn_id,
            requested_by_device_id=row.requested_by_device_id,
        )

    async def cancel(self, approval_id: str) -> bool:
        """Withdraw a pending request (its turn was cancelled or abandoned). True when it was
        pending; a withdrawn request can never be approved (`verify` raises `ApprovalReplayed`)."""
        async with self._sf() as session:
            done = await session.execute(
                update(ApprovalRow)
                .where(ApprovalRow.id == approval_id, ApprovalRow.status == "pending")
                .values(status="cancelled", decided_at=self._clock.now())
            )
            await session.commit()
        return affected_rows(done) == 1

    async def get(self, approval_id: str) -> ApprovalRequest | None:
        async with self._sf() as session:
            row = await session.get(ApprovalRow, approval_id)
            return self._to_request(row) if row is not None else None

    async def status(self, approval_id: str) -> str | None:
        """pending | approved | denied | expired | cancelled, or None when unknown."""
        async with self._sf() as session:
            row = await session.get(ApprovalRow, approval_id)
        if row is None:
            return None
        if row.status == "pending" and row.expires_at <= self._clock.now():
            return "expired"
        return row.status

    async def list_pending(self, *, turn_id: str | None = None) -> list[ApprovalRequest]:
        """Unanswered, unexpired requests, soonest expiry first."""
        stmt = (
            select(ApprovalRow)
            .where(ApprovalRow.status == "pending", ApprovalRow.expires_at > self._clock.now())
            .order_by(ApprovalRow.expires_at)
        )
        if turn_id is not None:
            stmt = stmt.where(ApprovalRow.turn_id == turn_id)
        async with self._sf() as session:
            return [self._to_request(row) for row in (await session.execute(stmt)).scalars().all()]

    # ------------------------------------------------------------ verify

    async def verify(self, decision: ApprovalDecision) -> ApprovalVerdict:
        """Verify a signed decision and consume the request.

        Order: exists -> not already answered (`ApprovalReplayed`) -> not expired (`ApprovalExpired`)
        -> digest matches (`ApprovalDigestMismatch`) -> active device and a valid signature from
        the key the level demands (`InvalidSignature`) -> atomic claim. A failed check leaves the
        request pending, so a wrong signature cannot burn it.
        """
        now = self._clock.now()
        async with self._sf() as session:
            row = await session.get(ApprovalRow, decision.approval_id)
        if row is None:
            raise ApprovalNotFound()
        if row.status != "pending":
            raise ApprovalReplayed()
        if row.expires_at <= now:
            await self._mark_expired(row.id)
            raise ApprovalExpired()
        if decision.action_digest != row.action_digest:
            raise ApprovalDigestMismatch()

        try:
            device = await self._devices.require_active(decision.device_id)
        except (DeviceNotFound, DeviceRevoked) as exc:
            raise InvalidSignature("The deciding device is not an active paired device.") from exc
        skew = timedelta(seconds=SIGNATURE_SKEW_SECONDS)
        if decision.signed_at > now + skew or decision.signed_at < row.created_at - skew:
            raise InvalidSignature("The decision was signed outside this request's lifetime.")

        level = ApprovalLevel(row.level)
        public_key = (
            device.approval_public_key_b64 if level is ApprovalLevel.BIOMETRIC else device.auth_public_key_b64
        )
        message = approval_message(row.id, row.action_digest, decision.approved, decision.signed_at)
        if not verify_signature(public_key, message, decision.signature_b64):
            raise InvalidSignature()

        async with self._sf() as session:
            claimed = await session.execute(
                update(ApprovalRow)
                .where(ApprovalRow.id == row.id, ApprovalRow.status == "pending")
                .values(
                    status="approved" if decision.approved else "denied",
                    decided_at=now,
                    decided_by_device_id=device.id,
                )
            )
            await session.commit()
        if affected_rows(claimed) != 1:
            raise ApprovalReplayed()
        return ApprovalVerdict(
            approval_id=row.id,
            approved=decision.approved,
            tool=row.tool,
            action_digest=row.action_digest,
            level=level,
            call_id=row.call_id,
            turn_id=row.turn_id,
            device_id=device.id,
        )

    async def _mark_expired(self, approval_id: str) -> None:
        async with self._sf() as session:
            await session.execute(
                update(ApprovalRow)
                .where(ApprovalRow.id == approval_id, ApprovalRow.status == "pending")
                .values(status="expired")
            )
            await session.commit()
