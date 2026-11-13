"""Registers the MCP gateway: the group servers at `/mcp/<group>`, the REST routes under `/v1/mcp`, the
external MCP client registry (service ``mcp_clients``), explicit external tool mappings and one
capability per group and per external server.
"""

from __future__ import annotations

import importlib
from pathlib import Path
from typing import TYPE_CHECKING

from app.core.types import CapabilityStatus
from app.schemas.security import Capability

from .api import build_router
from .clients import McpClientRegistry
from .config import McpConfigSource
from .external_tools import exposed_specs
from .oauth import McpOAuth
from .server import McpGateway

if TYPE_CHECKING:
    from app.plugins import PluginRegistry

CONFIG_FILE = "mcp_servers.yaml"


def config_path(reg: PluginRegistry) -> Path:
    return Path(reg.service("settings").config_dir) / CONFIG_FILE


def register_approval_owner(reg: PluginRegistry, gateway: McpGateway) -> None:
    """MCP calls answer the generic `POST /v1/approvals/{id}/decision` route."""
    from app.schemas.turns import ApprovalDecision, ApprovalDecisionResult
    from app.security.approvals import ApprovalLookup
    from app.security.sessions import AuthedDevice
    from app.tools.outcome import Completed, Denied, NeedsApproval

    from .schema import outcome_code
    from .server import CALL_PREFIX

    async def claims(lookup: ApprovalLookup) -> bool:
        return (lookup.call_id or "").startswith(CALL_PREFIX)

    async def decide(
        decision: ApprovalDecision, device: AuthedDevice, lookup: ApprovalLookup
    ) -> ApprovalDecisionResult:
        outcome = await gateway.resume_approval(decision)
        if isinstance(outcome, Completed):
            status = "completed"
        elif isinstance(outcome, NeedsApproval):
            status = "pending"
        elif isinstance(outcome, Denied):
            status = "denied"
        else:
            status = "failed"
        code = outcome_code(outcome) if outcome is not None else "approval_not_found"
        summary = outcome.summary if isinstance(outcome, Completed) else None
        return ApprovalDecisionResult(
            approval_id=decision.approval_id,
            owner="mcp",
            approved=decision.approved,
            status=status,
            turn_id=lookup.turn_id,
            result={"code": code, "summary": summary},
        )

    reg.service("approval_router").register("mcp", claims, decide)


def register(reg: PluginRegistry) -> None:
    require_device = importlib.import_module("app.api.deps").require_device
    config = McpConfigSource(config_path(reg))
    gateway = McpGateway(reg, config)
    clients = McpClientRegistry(
        config,
        oauth=McpOAuth(reg.service("secrets"), reg.service("clock")),
        privacy=reg.service("privacy_state"),
        audit=reg.service("audit"),
    )
    reg.provide("mcp_gateway", gateway)
    reg.provide("mcp_clients", clients)

    for spec in exposed_specs(config.current(), clients):
        reg.add_tool(spec)

    reg.add_router(build_router(gateway, clients, require_device))  # REST side: /v1/mcp/...
    # The gateway checks the kill switch itself (and audits), so the host guard is not needed.
    reg.add_mount("/mcp", gateway, guarded=False)
    register_approval_owner(reg, gateway)

    def group_capabilities() -> list[Capability]:
        caps = []
        for group in gateway.groups():
            count = len(gateway.exposed_tools(group))
            caps.append(
                Capability(
                    id=f"mcp.server.{group}",
                    title=f"MCP server: {group}",
                    domain="mcp",
                    status=CapabilityStatus.WORKING_LOCAL if count else CapabilityStatus.UNAVAILABLE,
                    requires=["device session token", f"device scope for {group} in {CONFIG_FILE}"],
                    note=f"{count} tools over Streamable HTTP at /mcp/{group}; calls above low "
                    "risk wait for the owner's approval.",
                )
            )
        return caps

    reg.add_capability(group_capabilities)
    reg.add_capability(clients.capabilities)
    reg.add_startup(gateway.start)
    reg.add_startup(clients.refresh_authorized)
    reg.add_shutdown(gateway.stop)
