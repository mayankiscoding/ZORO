"""`/healthz`, `/v1/capabilities`, `/v1/approvals/pending`, `/v1/approvals/{id}/decision`."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter

from app.api.dependencies import CurrentDevice, Registry
from app.schemas.common import Page
from app.schemas.security import Capability
from app.schemas.turns import ApprovalDecision, ApprovalDecisionResult, ApprovalRequest

health_router = APIRouter(tags=["system"])
capabilities_router = APIRouter(tags=["system"])
approvals_router = APIRouter(prefix="/approvals", tags=["approvals"])


@health_router.get("/healthz")
async def healthz(reg: Registry) -> dict[str, Any]:
    """Liveness plus a database ping. No authentication, so nothing private is reported."""
    database_ok = await reg.service("database").ping()
    return {
        "status": "ok" if database_ok else "degraded",
        "database": "ok" if database_ok else "unavailable",
        "server_time": reg.service("clock").now().isoformat(),
    }


@capabilities_router.get("/capabilities", response_model=Page[Capability])
async def list_capabilities(
    reg: Registry, device: CurrentDevice, domain: str | None = None
) -> Page[Capability]:
    return Page[Capability](items=reg.capabilities.all(domain=domain))


@approvals_router.get("/pending", response_model=Page[ApprovalRequest])
async def pending_approvals(reg: Registry, device: CurrentDevice) -> Page[ApprovalRequest]:
    items: list[ApprovalRequest] = await reg.service("approvals").list_pending()
    return Page[ApprovalRequest](items=items)


@approvals_router.post("/{approval_id}/decision", response_model=ApprovalDecisionResult)
async def decide_approval(
    approval_id: str, body: ApprovalDecision, reg: Registry, device: CurrentDevice
) -> ApprovalDecisionResult:
    """One way to answer any approval: the signed decision goes to whoever owns the call (a
    suspended turn, an MCP call, an automation run). The owner verifies it and runs exactly the
    digested arguments, or nothing."""
    result: ApprovalDecisionResult = await reg.service("approval_router").decide(approval_id, body, device)
    return result
