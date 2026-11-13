"""MCP gateway tests: the app with only the MCP plugin and a test-only tools plugin, a config
directory per test, and an SDK client that reaches the ASGI app in-process (no network)."""

from __future__ import annotations

from collections.abc import AsyncIterator, Callable, Sequence
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from pathlib import Path
from typing import Any

import httpx2
import pytest
import yaml
from fastapi import FastAPI
from mcp import Client
from mcp.client.streamable_http import streamable_http_client

from app.core.settings import Settings
from tests.mcp import tools_plugin


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.mcp.plugin", "tests.mcp.tools_plugin")


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    config_dir = tmp_path / "config"
    config_dir.mkdir()
    return Settings(
        _env_file=None,
        env="test",
        database_url=f"sqlite+aiosqlite:///{tmp_path / 'zoro.db'}",
        object_dir=tmp_path / "objects",
        local_dir=tmp_path / "local",
        config_dir=config_dir,
        secret_key=None,
        data_key=None,
    )


@pytest.fixture(autouse=True)
def _reset_sent() -> None:
    tools_plugin.SENT.clear()


WriteConfig = Callable[[dict[str, Any]], None]


@pytest.fixture
def write_config(settings: Settings) -> WriteConfig:
    def _write(data: dict[str, Any]) -> None:
        (settings.config_dir / "mcp_servers.yaml").write_text(yaml.safe_dump(data), encoding="utf-8")

    return _write


Connect = Callable[..., AbstractAsyncContextManager[Client]]


@pytest.fixture
def connect(app: FastAPI) -> Connect:
    """`async with connect("test-mcp", token) as client:` an SDK client over Streamable HTTP."""

    @asynccontextmanager
    async def _connect(group: str, token: str | None) -> AsyncIterator[Client]:
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        transport = httpx2.ASGITransport(app=app)
        async with httpx2.AsyncClient(
            transport=transport, base_url="http://zoro.test", headers=headers
        ) as http:
            stream = streamable_http_client(f"http://zoro.test/mcp/{group}", http_client=http)
            async with Client(stream, mode="legacy", read_timeout_seconds=10) as client:
                yield client

    return _connect
