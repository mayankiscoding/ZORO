"""`McpToolClient` on the official MCP Python SDK (Streamable HTTP + OAuth 2.1 / PKCE / DCR).

OAuth tokens and the dynamically registered client live encrypted in `SecretStore` under
``mcp:<provider>`` (accounts ``tokens`` and ``client``). Without tokens the client reports no
credentials and never opens a connection. `ConnectFlow` runs the owner's one-time authorisation:
`start()` returns the provider's authorisation URL, `finish(code, state)` completes it (the SDK checks
the state). Not exercised against the live server from this machine (no account connected).
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from typing import Any

import httpx2
from mcp.client import Client
from mcp.client.auth import AuthorizationCodeResult, OAuthClientProvider, OAuthFlowError
from mcp.client.streamable_http import streamable_http_client
from mcp.shared.auth import OAuthClientInformationFull, OAuthClientMetadata, OAuthToken

from app.security.secrets import SecretStore
from app.shopping.providers.swiggy import McpAuthRequired, McpCallResult, McpToolInfo

log = logging.getLogger(__name__)

_TIMEOUT_S = 20.0
_CONNECT_WAIT_S = 30.0


class SecretTokenStorage:
    """mcp `TokenStorage` backed by the kernel's encrypted `SecretStore`."""

    def __init__(self, secrets: SecretStore, provider_id: str) -> None:
        self._secrets = secrets
        self._key = f"mcp:{provider_id}"

    async def get_tokens(self) -> OAuthToken | None:
        raw = await self._secrets.get(self._key, account="tokens")
        return OAuthToken.model_validate_json(raw) if raw else None

    async def set_tokens(self, tokens: OAuthToken) -> None:
        await self._secrets.put(self._key, tokens.model_dump_json(), account="tokens")

    async def get_client_info(self) -> OAuthClientInformationFull | None:
        raw = await self._secrets.get(self._key, account="client")
        return OAuthClientInformationFull.model_validate_json(raw) if raw else None

    async def set_client_info(self, client_info: OAuthClientInformationFull) -> None:
        await self._secrets.put(self._key, client_info.model_dump_json(), account="client")

    async def clear(self) -> None:
        await self._secrets.delete(self._key)


def _metadata(redirect_uri: str) -> OAuthClientMetadata:
    return OAuthClientMetadata.model_validate(
        {
            "client_name": "ZORO personal assistant",
            "redirect_uris": [redirect_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        }
    )


class SdkMcpClient:
    """One short-lived MCP session per operation; tokens refresh through the SDK's OAuth provider."""

    def __init__(self, url: str, storage: SecretTokenStorage, redirect_uri: str) -> None:
        self._url = url
        self._storage = storage
        self._redirect_uri = redirect_uri

    async def has_credentials(self) -> bool:
        return await self._storage.get_tokens() is not None

    def _auth(self) -> OAuthClientProvider:
        return OAuthClientProvider(
            server_url=self._url, client_metadata=_metadata(self._redirect_uri), storage=self._storage
        )

    @contextlib.asynccontextmanager
    async def _session(self) -> Any:
        async with httpx2.AsyncClient(auth=self._auth(), timeout=httpx2.Timeout(_TIMEOUT_S)) as http:
            try:
                async with Client(
                    streamable_http_client(self._url, http_client=http), read_timeout_seconds=_TIMEOUT_S
                ) as client:
                    yield client
            except OAuthFlowError as exc:
                raise McpAuthRequired(str(exc)) from exc

    async def list_tools(self) -> list[McpToolInfo]:
        tools: list[McpToolInfo] = []
        async with self._session() as client:
            cursor: str | None = None
            for _ in range(20):
                page = await client.list_tools(cursor=cursor)
                tools.extend(McpToolInfo(name=t.name, description=t.description or "") for t in page.tools)
                cursor = page.next_cursor
                if not cursor:
                    break
        return tools

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> McpCallResult:
        async with self._session() as client:
            result = await client.call_tool(name, arguments)
        text = "".join(getattr(block, "text", "") for block in result.content or [])
        structured = result.structured_content if isinstance(result.structured_content, dict) else None
        return McpCallResult(structured=structured, text=text, is_error=bool(result.is_error))


class ConnectFlow:
    """The owner's one-time OAuth authorisation for an MCP provider (one pending flow at a time)."""

    def __init__(self, url: str, storage: SecretTokenStorage, redirect_uri: str) -> None:
        self._url = url
        self._storage = storage
        self._redirect_uri = redirect_uri
        self._task: asyncio.Task[None] | None = None
        self._code: asyncio.Future[AuthorizationCodeResult] | None = None

    @property
    def pending(self) -> bool:
        return self._task is not None and not self._task.done()

    async def start(self) -> str:
        """Begin registration + authorisation; returns the URL the owner opens to approve access."""
        if self._task is not None:
            self._task.cancel()
        loop = asyncio.get_running_loop()
        auth_url: asyncio.Future[str] = loop.create_future()
        self._code = loop.create_future()
        code_future = self._code

        async def on_redirect(url: str) -> None:
            if not auth_url.done():
                auth_url.set_result(url)

        async def on_callback() -> AuthorizationCodeResult:
            return await asyncio.wait_for(code_future, timeout=600)

        provider = OAuthClientProvider(
            server_url=self._url,
            client_metadata=_metadata(self._redirect_uri),
            storage=self._storage,
            redirect_handler=on_redirect,
            callback_handler=on_callback,
        )

        async def run() -> None:
            async with (
                httpx2.AsyncClient(auth=provider, timeout=httpx2.Timeout(_TIMEOUT_S)) as http,
                Client(streamable_http_client(self._url, http_client=http)) as client,
            ):
                await client.list_tools()

        self._task = asyncio.create_task(run())
        done, _ = await asyncio.wait(  # type: ignore[type-var]
            {auth_url, self._task}, timeout=_CONNECT_WAIT_S, return_when="FIRST_COMPLETED"
        )
        if auth_url in done:
            return auth_url.result()
        if self._task in done and self._task.exception() is None:
            return ""  # already authorised: tokens were valid
        raise McpAuthRequired("authorisation could not start")

    async def finish(self, code: str, state: str | None) -> bool:
        """Hand the redirect's code to the waiting flow; True once tokens are stored."""
        if self._code is None or self._task is None:
            return False
        if not self._code.done():
            self._code.set_result(AuthorizationCodeResult(code=code, state=state))
        try:
            await asyncio.wait_for(self._task, timeout=_CONNECT_WAIT_S)
        except Exception as exc:
            log.warning("mcp connect failed", extra={"error_type": type(exc).__name__})
            return False
        return await self._storage.get_tokens() is not None
