"""MCP gateway, client side: calls to allowlisted external MCP servers (service ``mcp_clients``).

Every call: server known and enabled -> tool on the server's allowlist -> transport allowed (stdio
only for allowlisted absolute commands; none by default) -> egress decision for the server's
locality and the classes it may receive -> credentials -> call with a timeout -> result size-limited,
wrapped as untrusted, turn tainted -> audit. External results are data, never instructions.
"""

from __future__ import annotations

import json
import logging
import os
from collections.abc import AsyncIterator, Callable, Iterable, Mapping
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from datetime import datetime
from typing import Any, Protocol

import anyio
import httpx2
import mcp_types as types
from mcp import Client, StdioServerParameters
from mcp.client.streamable_http import streamable_http_client
from pydantic import BaseModel

from app.core.types import CapabilityStatus, DataClass, IntegrationLevel
from app.schemas.security import Capability
from app.security.audit import AuditLog
from app.security.egress import decide_egress
from app.security.privacy import PrivacyStateService, stricter_mode
from app.security.redaction import redact_text
from app.security.taint import wrap_untrusted
from app.tools.spec import ToolContext

from .config import AuthBearer, AuthOAuth, ExternalServer, McpConfigSource
from .oauth import McpOAuth

log = logging.getLogger(__name__)


class ExternalMcpError(Exception):
    """A refused or failed external call. `code` is stable: server_unknown, server_disabled,
    tool_not_allowed, stdio_not_allowed, egress_denied:<reason>, credentials_missing,
    timeout, server_error."""

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code


class ExternalCallResult(BaseModel):
    server: str
    tool: str
    content: str  # wrapped: <untrusted source="mcp:server/tool">…</untrusted>
    is_error: bool
    truncated: bool
    untrusted: bool = True
    retrieved_at: datetime


class ToolCaller(Protocol):
    async def call_tool(
        self, name: str, arguments: dict[str, Any] | None = None, read_timeout_seconds: float | None = None
    ) -> types.CallToolResult: ...


Connector = Callable[[ExternalServer, Mapping[str, str]], AbstractAsyncContextManager[ToolCaller]]


@asynccontextmanager
async def default_connector(server: ExternalServer, headers: Mapping[str, str]) -> AsyncIterator[ToolCaller]:
    """The SDK client over Streamable HTTP (its HTTP stack is `httpx2`), or over stdio for an
    allowlisted absolute command, launched without a shell and with an empty environment."""
    if server.transport == "stdio":
        assert server.command is not None
        params = StdioServerParameters(command=server.command, args=list(server.args), env={})
        async with Client(params, read_timeout_seconds=server.timeout_s) as client:
            yield client
        return
    assert server.url is not None
    timeout = httpx2.Timeout(server.timeout_s)
    async with httpx2.AsyncClient(headers=dict(headers), timeout=timeout, follow_redirects=False) as http:
        transport = streamable_http_client(server.url, http_client=http)
        async with Client(transport, read_timeout_seconds=server.timeout_s) as client:
            yield client


class McpClientRegistry:
    def __init__(
        self,
        config: McpConfigSource,
        *,
        oauth: McpOAuth,
        privacy: PrivacyStateService,
        audit: AuditLog,
        connector: Connector = default_connector,
        env: Mapping[str, str] | None = None,
    ) -> None:
        self._config = config
        self._oauth = oauth
        self._privacy = privacy
        self._audit = audit
        self._connector = connector
        self._env = env
        self._authorized: set[str] = set()  # oauth servers holding tokens (refreshed at startup)

    @property
    def oauth(self) -> McpOAuth:
        return self._oauth

    def servers(self) -> list[ExternalServer]:
        return list(self._config.current().clients.servers)

    def get(self, name: str) -> ExternalServer | None:
        return self._config.current().clients.get(name)

    def _getenv(self, key: str) -> str | None:
        return (self._env if self._env is not None else os.environ).get(key) or None

    # ------------------------------------------------------------ status

    async def refresh_authorized(self) -> None:
        names = set()
        for server in self.servers():
            if isinstance(server.auth, AuthOAuth) and await self._oauth.tokens(server) is not None:
                names.add(server.name)
        self._authorized = names

    def mark_authorized(self, name: str, authorized: bool = True) -> None:
        (self._authorized.add if authorized else self._authorized.discard)(name)

    def capabilities(self) -> list[Capability]:
        """One per configured server. Status reflects configuration and credentials, never a probe."""
        stdio_allowed = set(self._config.current().clients.stdio_command_allowlist)
        caps: list[Capability] = []
        for server in self.servers():
            requires: list[str] = []
            if not server.enabled:
                status, note = CapabilityStatus.UNAVAILABLE, "Disabled in config/mcp_servers.yaml."
            elif server.transport == "stdio" and server.command not in stdio_allowed:
                status, note = CapabilityStatus.UNAVAILABLE, "stdio command is not on the allowlist."
            elif isinstance(server.auth, AuthBearer) and self._getenv(server.auth.token_env) is None:
                requires = [server.auth.token_env]
                status, note = CapabilityStatus.REQUIRES_CREDENTIALS, f"Set {server.auth.token_env}."
            elif isinstance(server.auth, AuthOAuth) and server.name not in self._authorized:
                requires = ["oauth"]
                status, note = CapabilityStatus.REQUIRES_CREDENTIALS, "Sign in to this server from the app."
            else:
                status, note = (
                    CapabilityStatus.WORKING_INTEGRATION,
                    "Configured; reachability is not checked.",
                )
            caps.append(
                Capability(
                    id=f"mcp.external.{server.name}",
                    title=f"External MCP server: {server.display_name}",
                    domain="mcp",
                    status=status,
                    integration_level=IntegrationLevel.OFFICIAL_API,
                    requires=requires,
                    note=note,
                )
            )
        return caps

    # ------------------------------------------------------------ calls

    async def call(
        self,
        ctx: ToolContext,
        server_name: str,
        tool: str,
        arguments: Mapping[str, Any],
        *,
        data_classes: Iterable[DataClass] = (DataClass.PERSONAL,),
    ) -> ExternalCallResult:
        server = self.get(server_name)
        try:
            payload = await self._checked_arguments(ctx, server, server_name, tool, arguments, data_classes)
            assert server is not None
            headers = await self._headers(server)
            with anyio.fail_after(server.timeout_s + 5):
                async with self._connector(server, headers) as client:
                    raw = await client.call_tool(tool, payload, read_timeout_seconds=server.timeout_s)
        except ExternalMcpError as exc:
            await self._note(ctx, server_name, tool, "denied", exc.code)
            raise
        except TimeoutError as exc:
            await self._note(ctx, server_name, tool, "failed", "timeout")
            raise ExternalMcpError("timeout", f"{server_name} did not answer in time") from exc
        except Exception as exc:
            await self._note(ctx, server_name, tool, "failed", f"server_error {type(exc).__name__}")
            raise ExternalMcpError("server_error", f"{server_name} failed: {type(exc).__name__}") from exc
        result = self._wrap(server, tool, raw, ctx.now())
        ctx.mark_tainted()
        await self._note(
            ctx, server_name, tool, "allowed", f"ok truncated={result.truncated} untrusted_output"
        )
        return result

    async def _checked_arguments(
        self, ctx: ToolContext, server: ExternalServer | None, server_name: str, tool: str,
        arguments: Mapping[str, Any], data_classes: Iterable[DataClass],
    ) -> dict[str, Any]:  # fmt: skip
        if server is None:
            raise ExternalMcpError("server_unknown", f"no external MCP server named {server_name!r}")
        if not server.enabled:
            raise ExternalMcpError("server_disabled", f"{server.name} is disabled in config")
        if tool not in server.allowed_tools:
            raise ExternalMcpError("tool_not_allowed", f"{tool!r} is not allowed on {server.name}")
        if (
            server.transport == "stdio"
            and server.command not in self._config.current().clients.stdio_command_allowlist
        ):
            raise ExternalMcpError("stdio_not_allowed", "stdio servers need an allowlisted absolute command")
        classes = frozenset(data_classes) or frozenset({DataClass.PERSONAL})
        granted = frozenset(server.data_classes)
        if not classes <= granted:
            blocked = ",".join(sorted(c.value for c in classes - granted))
            raise ExternalMcpError(f"egress_denied:class_not_granted:{blocked}", "data class not granted")
        mode = stricter_mode(await self._privacy.get_mode(), ctx.privacy_mode)
        allow_public, _ = await self._privacy.egress_overrides()
        decision = decide_egress(
            mode=mode, data_classes=classes, locality=server.locality,
            provider_allowed=granted, strict_allow_public_external=allow_public,
        )  # fmt: skip
        if not decision.allowed:
            raise ExternalMcpError(f"egress_denied:{decision.reason}", "privacy policy refused sending this")
        payload: dict[str, Any] = json.loads(json.dumps(dict(arguments), default=str))
        return _redact(payload) if decision.redact else payload

    async def _headers(self, server: ExternalServer) -> dict[str, str]:
        if isinstance(server.auth, AuthBearer):
            token = self._getenv(server.auth.token_env)
            if token is None:
                raise ExternalMcpError("credentials_missing", f"set {server.auth.token_env}")
            return {"Authorization": f"Bearer {token}"}
        if isinstance(server.auth, AuthOAuth):
            access = await self._oauth.access_token(server)
            self.mark_authorized(server.name, access is not None)
            if access is None:
                raise ExternalMcpError("credentials_missing", f"sign in to {server.name} from the app")
            return {"Authorization": f"Bearer {access}"}
        return {}

    @staticmethod
    def _wrap(
        server: ExternalServer, tool: str, raw: types.CallToolResult, now: datetime
    ) -> ExternalCallResult:
        parts: list[str] = []
        for block in raw.content:
            if isinstance(block, types.TextContent):
                parts.append(block.text)
            else:
                parts.append(f"[{block.type} content omitted]")
        if raw.structured_content is not None:
            parts.append(json.dumps(raw.structured_content, ensure_ascii=False, default=str))
        text = "\n".join(parts)
        encoded = text.encode("utf-8")
        truncated = len(encoded) > server.max_result_bytes
        if truncated:
            text = encoded[: server.max_result_bytes].decode("utf-8", errors="ignore") + "\n[truncated]"
        return ExternalCallResult(
            server=server.name,
            tool=tool,
            content=wrap_untrusted(text, source=f"mcp:{server.name}/{tool}"),
            is_error=bool(raw.is_error),
            truncated=truncated,
            retrieved_at=now,
        )

    async def _note(self, ctx: ToolContext, server: str, tool: str, decision: Any, detail: str) -> None:
        await self._audit.append(
            actor=ctx.agent.value,
            action="mcp.external_call",
            decision=decision,
            tool=f"{server[:60]}/{tool[:120]}",
            detail=f"{detail} turn={ctx.turn_id}",
        )


def _redact(value: Any) -> Any:  # strings anywhere in the JSON arguments
    if isinstance(value, str):
        return redact_text(value).text
    if isinstance(value, list):
        return [_redact(item) for item in value]
    if isinstance(value, dict):
        return {key: _redact(item) for key, item in value.items()}
    return value


__all__ = [
    "Connector",
    "ExternalCallResult",
    "ExternalMcpError",
    "McpClientRegistry",
    "default_connector",
]
