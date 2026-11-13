"""REST side of the MCP gateway (mounted under `/v1`, device token required):

- `POST /v1/mcp/approvals/{approval_id}/decision`  the owner's signed decision for an MCP call
- `GET  /v1/mcp/servers`                            external MCP servers and their status
- `POST /v1/mcp/servers/{name}/oauth/start`         begin OAuth 2.1 + PKCE sign-in
- `POST /v1/mcp/servers/{name}/oauth/complete`      finish it with the code and state
"""

from __future__ import annotations

from typing import Any, Literal

from fastapi import APIRouter, Depends

from app.core.errors import BadRequest, Forbidden, NotFound, Unavailable
from app.schemas.common import ZModel
from app.schemas.turns import ApprovalDecision
from app.security.sessions import AuthedDevice
from app.tools.outcome import Completed, Denied, NeedsApproval

from .clients import McpClientRegistry
from .config import AuthOAuth, ExternalServer
from .oauth import OAuthError
from .schema import outcome_code
from .server import McpGateway


class McpApprovalResult(ZModel):
    approval_id: str
    status: Literal["completed", "denied", "failed", "pending"]
    code: str
    summary: str | None = None


class ExternalServerView(ZModel):
    name: str
    title: str
    enabled: bool
    transport: str
    locality: str
    auth: str
    allowed_tools: list[str]
    data_classes: list[str]
    status: str


class OAuthStartResponse(ZModel):
    authorization_url: str
    state: str


class OAuthCompleteRequest(ZModel):
    code: str
    state: str


class OAuthCompleteResponse(ZModel):
    server: str
    authorized: bool


def build_router(gateway: McpGateway, clients: McpClientRegistry, require_device: Any) -> APIRouter:
    router = APIRouter(prefix="/mcp", tags=["mcp"])
    Device = Depends(require_device)

    @router.post("/approvals/{approval_id}/decision", response_model=McpApprovalResult)
    async def decide(
        approval_id: str, decision: ApprovalDecision, device: AuthedDevice = Device
    ) -> McpApprovalResult:
        if decision.approval_id != approval_id:
            raise BadRequest("The decision is for a different approval.")
        if decision.device_id != device.device_id:
            raise Forbidden("A device can only submit its own signed decisions.")
        outcome = await gateway.resume_approval(decision)
        if outcome is None:
            raise NotFound("No MCP call is waiting for this approval.")
        status: Literal["completed", "denied", "failed", "pending"]
        if isinstance(outcome, Completed):
            status = "completed"
        elif isinstance(outcome, NeedsApproval):
            status = "pending"
        elif isinstance(outcome, Denied):
            status = "denied"
        else:
            status = "failed"
        summary = outcome.summary if isinstance(outcome, Completed) else None
        return McpApprovalResult(
            approval_id=approval_id, status=status, code=outcome_code(outcome), summary=summary
        )

    @router.get("/servers", response_model=list[ExternalServerView])
    async def servers(device: AuthedDevice = Device) -> list[ExternalServerView]:
        status = {cap.id: cap.status.value for cap in clients.capabilities()}
        return [
            ExternalServerView(
                name=s.name,
                title=s.display_name,
                enabled=s.enabled,
                transport=s.transport,
                locality=s.locality.value,
                auth=s.auth.kind,
                allowed_tools=list(s.allowed_tools),
                data_classes=[c.value for c in s.data_classes],
                status=status.get(f"mcp.external.{s.name}", "unavailable"),
            )
            for s in clients.servers()
        ]

    def oauth_server(name: str) -> ExternalServer:
        server = clients.get(name)
        if server is None or not server.enabled:
            raise NotFound("No enabled external MCP server with this name.")
        if not isinstance(server.auth, AuthOAuth):
            raise BadRequest("This server does not use OAuth.")
        return server

    @router.post("/servers/{name}/oauth/start", response_model=OAuthStartResponse)
    async def oauth_start(name: str, device: AuthedDevice = Device) -> OAuthStartResponse:
        server = oauth_server(name)
        try:
            started = await clients.oauth.start(server)
        except OAuthError as exc:
            raise Unavailable(f"Sign-in could not start: {exc.code}") from exc
        return OAuthStartResponse(authorization_url=started.url, state=started.state)

    @router.post("/servers/{name}/oauth/complete", response_model=OAuthCompleteResponse)
    async def oauth_complete(
        name: str, body: OAuthCompleteRequest, device: AuthedDevice = Device
    ) -> OAuthCompleteResponse:
        server = oauth_server(name)
        try:
            await clients.oauth.complete(server, code=body.code, state=body.state)
        except OAuthError as exc:
            raise BadRequest(f"Sign-in failed: {exc.code}") from exc
        clients.mark_authorized(server.name)
        return OAuthCompleteResponse(server=server.name, authorized=True)

    return router
