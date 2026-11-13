"""MCP gateway, server side: one MCP server per tool group, served over Streamable HTTP.

`McpGateway` is an ASGI app mounted at `/mcp`; `/mcp/<group>` reaches the server built for
that `ToolSpec.mcp_group`. Every request: kill switch -> bearer device token -> the device's group
scope (config) -> request rate limit -> MCP. Every `tools/call` is just another caller of
`ToolExecutor`, with `user_initiated=False`, so MEDIUM and above wait for the owner's signed
approval. Device tools are pushed through the registered `DeviceDispatcher`.
"""

from __future__ import annotations

import asyncio
import json
import logging
from contextlib import AsyncExitStack
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

import mcp_types as types
from mcp.server.context import ServerRequestContext
from mcp.server.lowlevel import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from sqlalchemy import select
from starlette.types import Receive, Scope, Send

from app.core.errors import ZoroError
from app.core.ids import new_id
from app.core.types import AgentId
from app.schemas.turns import ApprovalDecision
from app.security.audit import AuditDecision
from app.security.models import ApprovalRow
from app.tools.dispatcher import DeviceNoAnswer, DeviceOffline
from app.tools.outcome import Completed, Denied, Failed, NeedsApproval, NeedsDeviceAction, ToolOutcome
from app.tools.ratelimit import TokenBucketRateLimiter
from app.tools.spec import ToolContext, ToolSpec

from .config import McpConfigSource
from .schema import APPROVAL_ARG, APPROVAL_META, error_result, outcome_code, to_call_result, to_mcp_tool

if TYPE_CHECKING:
    from app.plugins import PluginRegistry

log = logging.getLogger(__name__)

CALLER_SCOPE_KEY = "zoro.mcp.caller"
NOT_SERVED_GROUP = "external-mcp"  # `external_tools.EXTERNAL_GROUP`
CALL_PREFIX = "mcp_"
_DEVICE_GRACE_S = 2.0


@dataclass(frozen=True)
class McpCaller:
    """The authenticated device behind one MCP HTTP request and the group it addressed."""

    device_id: str
    group: str


def acting_agent(spec: ToolSpec) -> AgentId | None:
    """The agent an MCP call runs as: the personal assistant when the tool allows it, otherwise the
    tool's first allowlisted agent. MCP access itself is granted per device and group in config."""
    if AgentId.PERSONAL_ASSISTANT in spec.agents:
        return AgentId.PERSONAL_ASSISTANT
    return min(spec.agents, key=lambda a: a.value) if spec.agents else None


class McpGateway:
    def __init__(self, reg: PluginRegistry, config: McpConfigSource) -> None:
        self._reg = reg
        self._config = config
        self._managers: dict[str, StreamableHTTPSessionManager] = {}
        self._runner: asyncio.Task[None] | None = None
        self._stopping: asyncio.Event | None = None
        self._limiter = TokenBucketRateLimiter()

    # ------------------------------------------------------------ registry view

    def groups(self) -> list[str]:
        """Groups served at `/mcp/<group>`: every tool group except tools that came from an
        external MCP server (those are never passed back out)."""
        return [group for group in self._reg.tools.groups() if group != NOT_SERVED_GROUP]

    def exposed_tools(self, group: str) -> list[ToolSpec]:
        max_rank = self._config.current().gateway.max_risk.rank
        return [
            spec
            for spec in self._reg.tools.for_group(group)
            if spec.risk.rank <= max_rank and acting_agent(spec) is not None
        ]

    @property
    def served_groups(self) -> list[str]:
        return sorted(self._managers)

    # ------------------------------------------------------------ lifecycle

    def _build_server(self, group: str) -> Server[Any]:
        async def list_tools(
            ctx: ServerRequestContext[Any, Any], params: types.PaginatedRequestParams | None
        ) -> types.ListToolsResult:
            self._caller(ctx, group)
            return types.ListToolsResult(tools=[to_mcp_tool(spec) for spec in self.exposed_tools(group)])

        async def call_tool(
            ctx: ServerRequestContext[Any, Any], params: types.CallToolRequestParams
        ) -> types.CallToolResult:
            return await self.call(self._caller(ctx, group), params)

        return Server(
            group,
            version="1",
            instructions=f"ZORO tools of {group}. Calls above low risk wait for the owner's approval.",
            on_list_tools=list_tools,
            on_call_tool=call_tool,
        )

    async def start(self) -> None:
        """Build a server per group and run its session manager (called from a startup hook, once
        every plugin has registered its tools). The managers' task groups live in one dedicated
        task, so they are entered and exited in the same task whoever calls `start` / `stop`."""
        if self._runner is not None:
            return
        limits = self._config.current().gateway
        managers = {
            group: StreamableHTTPSessionManager(
                app=self._build_server(group),
                json_response=True,
                stateless=True,  # every request carries and proves the device token
                max_request_body_size=limits.max_request_bytes,
            )
            for group in self.groups()
        }
        ready = asyncio.Event()
        self._stopping = asyncio.Event()
        stopping = self._stopping

        async def run() -> None:
            async with AsyncExitStack() as stack:
                for manager in managers.values():
                    await stack.enter_async_context(manager.run())
                self._managers = managers
                ready.set()
                try:
                    await stopping.wait()
                finally:
                    self._managers = {}

        self._runner = asyncio.create_task(run(), name="mcp-gateway")
        waiter = asyncio.create_task(ready.wait())
        await asyncio.wait({self._runner, waiter}, return_when=asyncio.FIRST_COMPLETED)
        if not ready.is_set():
            waiter.cancel()
            runner, self._runner = self._runner, None
            runner.result()  # raises what stopped the managers from starting

    async def stop(self) -> None:
        runner, self._runner = self._runner, None
        if runner is None:
            return
        if self._stopping is not None:
            self._stopping.set()
        await runner

    # ------------------------------------------------------------ HTTP

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            return
        path = str(scope.get("path", ""))
        root = str(scope.get("root_path", ""))
        group = (path[len(root) :] if root and path.startswith(root) else path).strip("/")
        manager = self._managers.get(group)
        if manager is None:
            await _reply(send, 404, "not_found", "No MCP server at this path.")
            return
        if await self._reg.service("kill_switch").is_on():
            await _reply(send, 503, "kill_switch_active", "The kill switch is on.")
            return
        device_id = await self._authenticate(scope)
        if device_id is None:
            await self._audit(None, group, "mcp.auth", "denied", "unauthenticated")
            await _reply(send, 401, "unauthorized", "Send a device session token as a Bearer token.")
            return
        limits = self._config.current().gateway
        if not limits.allows(device_id, group):
            await self._audit(device_id, group, "mcp.auth", "denied", "group_not_in_scope")
            await _reply(send, 403, "forbidden", "This device may not use this MCP group.")
            return
        if not self._limiter.allow(f"{device_id}:{group}", limits.requests_per_minute):
            await _reply(send, 429, "rate_limited", "Too many MCP requests; slow down.", retryable=True)
            return
        child = dict(scope)
        child[CALLER_SCOPE_KEY] = McpCaller(device_id=device_id, group=group)
        await manager.handle_request(child, receive, send)

    async def _authenticate(self, scope: Scope) -> str | None:
        header = next((v for k, v in scope.get("headers", []) if k == b"authorization"), b"")
        scheme, _, token = header.decode("latin-1").partition(" ")
        if scheme.lower() != "bearer" or not token.strip():
            return None
        try:
            device = await self._reg.service("sessions").authenticate(token.strip())
        except ZoroError:
            return None
        await self._reg.service("devices").touch(device.device_id)
        return str(device.device_id)

    @staticmethod
    def _caller(ctx: ServerRequestContext[Any, Any], group: str) -> McpCaller:
        """Defence in depth: a handler only runs for a request the HTTP layer authenticated."""
        request = ctx.request
        caller = request.scope.get(CALLER_SCOPE_KEY) if request is not None else None
        if not isinstance(caller, McpCaller) or caller.group != group:
            raise PermissionError("unauthenticated MCP request")
        return caller

    # ------------------------------------------------------------ tools/call

    async def call(self, caller: McpCaller, params: types.CallToolRequestParams) -> types.CallToolResult:
        limits = self._config.current().gateway
        spec = next((s for s in self.exposed_tools(caller.group) if s.name == params.name), None)
        if spec is None:
            await self._audit(caller.device_id, caller.group, "mcp.call", "denied", "unknown_tool")
            return error_result("unknown_tool", f"{caller.group} has no tool named {params.name[:80]!r}.")
        args = dict(params.arguments or {})
        approval_id = args.pop(APPROVAL_ARG, None)
        meta: dict[str, Any] = dict(params.meta or {})
        approval_id = approval_id or meta.get(APPROVAL_META)
        try:
            outcome = await asyncio.wait_for(
                self._invoke(caller, spec, args, approval_id), timeout=limits.call_timeout_s
            )
        except TimeoutError:
            outcome = Failed("timeout", tool=spec.name, retryable=True, message="The call took too long.")
        result = to_call_result(spec, outcome, max_result_bytes=limits.max_result_bytes)
        code = (
            "result_too_large"
            if result.is_error and isinstance(outcome, Completed)
            else outcome_code(outcome)
        )
        await self._audit(caller.device_id, caller.group, "mcp.call", _decision(outcome, code), code, spec)
        return result

    async def _invoke(
        self, caller: McpCaller, spec: ToolSpec, args: dict[str, Any], approval_id: Any
    ) -> ToolOutcome:
        executor = self._reg.service("tool_executor")
        if approval_id is None:
            agent = acting_agent(spec)
            assert agent is not None  # exposed_tools filtered tools without one
            call_id = new_id(CALL_PREFIX.rstrip("_"))
            ctx = await self._context(call_id, agent, caller.device_id)
            outcome: ToolOutcome = await executor.execute(ctx, spec.name, args, call_id=call_id)
        else:
            row = await self._mcp_approval(str(approval_id))
            if row is None or row.tool != spec.name or row.requested_by_device_id != caller.device_id:
                return Denied(
                    "approval_not_found", tool=spec.name, message="No such MCP approval for this call."
                )
            assert row.call_id is not None and row.agent is not None
            ctx = await self._context(row.turn_id or row.call_id, AgentId(row.agent), caller.device_id)
            # A known call_id re-enters the journal: the stored outcome when the owner approved,
            # "still pending" otherwise, and call_id_conflict when the arguments differ.
            outcome = await executor.execute(ctx, spec.name, args, call_id=row.call_id)
        return await self._through_device(ctx, outcome)

    async def resume_approval(self, decision: ApprovalDecision) -> ToolOutcome | None:
        """The owner's signed decision for an MCP call: verify it and run exactly the digested
        arguments now; the client's retry then collects the journaled outcome. None when the
        approval does not belong to an MCP call."""
        row = await self._mcp_approval(decision.approval_id)
        if row is None or row.call_id is None or row.agent is None:
            return None
        ctx = await self._context(row.turn_id or row.call_id, AgentId(row.agent), row.requested_by_device_id)
        outcome = await self._reg.service("tool_executor").resume_with_approval(ctx, row.call_id, decision)
        return await self._through_device(ctx, outcome)

    async def _through_device(self, ctx: ToolContext, outcome: ToolOutcome) -> ToolOutcome:
        """The MCP caller is not the app's turn stream, so a device action is pushed through the
        registered dispatcher and the result fed back to the executor."""
        if not isinstance(outcome, NeedsDeviceAction):
            return outcome
        request = outcome.request
        target = request.target_device_id or ctx.device_id
        window = max(0.0, (request.expires_at - ctx.now()).total_seconds())
        if target is None:
            return Failed("device_unavailable", call_id=outcome.call_id, tool=outcome.tool)
        try:
            result = await asyncio.wait_for(
                self._reg.device_dispatcher.dispatch(target, request, window),
                timeout=window + _DEVICE_GRACE_S,
            )
        except (DeviceNoAnswer, TimeoutError):
            # Delivered, no answer: the device may have acted, so this is not retryable.
            return Failed("device_timeout", call_id=outcome.call_id, tool=outcome.tool, retryable=False,
                          message="The device did not confirm in time. It may have run.")  # fmt: skip
        except DeviceOffline:
            return Failed("device_offline", call_id=outcome.call_id, tool=outcome.tool, retryable=True,
                          message="The device that runs this action is not connected.")  # fmt: skip
        executor = self._reg.service("tool_executor")
        resumed: ToolOutcome = await executor.resume_with_device_result(ctx, outcome.call_id, result)
        return resumed

    async def _context(self, turn_id: str, agent: AgentId, device_id: str | None) -> ToolContext:
        privacy = await self._reg.service("privacy_state").get_mode()
        return self._reg.tool_context(
            turn_id=turn_id, agent=agent, device_id=device_id, privacy_mode=privacy, user_initiated=False
        )

    async def _mcp_approval(self, approval_id: str) -> ApprovalRow | None:
        async with self._reg.service("session_factory")() as session:
            row: ApprovalRow | None = (
                await session.execute(select(ApprovalRow).where(ApprovalRow.id == approval_id[:64]))
            ).scalar_one_or_none()
        if row is None or not (row.call_id or "").startswith(CALL_PREFIX) or row.agent is None:
            return None
        return row

    async def _audit(
        self, device_id: str | None, group: str, action: str, decision: AuditDecision, detail: str,
        spec: ToolSpec | None = None,
    ) -> None:  # fmt: skip
        await self._reg.service("audit").append(
            actor=device_id or "anonymous",
            action=action,
            decision=decision,
            tool=spec.name if spec is not None else None,
            risk=spec.risk if spec is not None else None,
            data_classes=spec.data_classes if spec is not None else (),
            detail=f"group={group} {detail}",
        )


def _decision(outcome: ToolOutcome, code: str) -> AuditDecision:
    if isinstance(outcome, Completed):
        return "failed" if code == "result_too_large" else "allowed"
    if isinstance(outcome, NeedsApproval | NeedsDeviceAction):
        return "info"
    if isinstance(outcome, Denied):
        return "blocked" if outcome.reason == "kill_switch" else "denied"
    return "failed"


async def _reply(send: Send, status: int, code: str, message: str, *, retryable: bool = False) -> None:
    body = json.dumps({"code": code, "message": message, "retryable": retryable}).encode()
    headers = [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]
    if status == 401:
        headers.append((b"www-authenticate", b"Bearer"))
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})
