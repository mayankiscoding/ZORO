"""Shared fixtures for every backend package.

- `settings`        isolated test settings (SQLite file and object store under `tmp_path`)
- `plugin_modules`  which plugins the app loads; override it in a package's own conftest to narrow
- `clock`           the app's clock; override it with a `FixedClock` to control time
- `app`             the FastAPI app with its lifespan running (tables created, startup hooks run)
- `registry`        `app.state.registry` (the `PluginRegistry`)
- `client`          httpx.AsyncClient over ASGITransport
- `db`              an `AsyncSession` on the app's database
- `paired_device`   a paired, signed-in device with software keys (`.signer`, `.headers`)
- `pair_device`     factory for more devices

Tests marked `postgres` run only when ZORO_TEST_DATABASE_URL points at PostgreSQL + pgvector.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator, Awaitable, Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import Clock, SystemClock
from app.core.settings import Settings
from app.core.types import DevicePlatform
from app.main import create_app
from app.plugins import PLUGIN_MODULES, PluginRegistry
from tests.fakes.devices import DeviceSigner


@dataclass
class PairedDevice:
    device_id: str
    signer: DeviceSigner
    token: str

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}


PairDevice = Callable[..., Awaitable[PairedDevice]]


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if os.environ.get("ZORO_TEST_DATABASE_URL"):
        return
    skip = pytest.mark.skip(reason="needs PostgreSQL + pgvector: set ZORO_TEST_DATABASE_URL")
    for item in items:
        if "postgres" in item.keywords:
            item.add_marker(skip)


@pytest.fixture
def settings(tmp_path: Path, request: pytest.FixtureRequest) -> Settings:
    database_url = f"sqlite+aiosqlite:///{tmp_path / 'zoro.db'}"
    if request.node.get_closest_marker("postgres") is not None:
        database_url = os.environ.get("ZORO_TEST_DATABASE_URL", database_url)
    return Settings(
        _env_file=None,
        env="test",
        database_url=database_url,
        object_dir=tmp_path / "objects",
        local_dir=tmp_path / "local",
        secret_key=None,
        data_key=None,
    )


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    """Every plugin that exists, as in production. Narrow it per package when that helps."""
    return PLUGIN_MODULES


@pytest.fixture
def clock() -> Clock:
    return SystemClock()


@pytest.fixture
async def app(settings: Settings, plugin_modules: Sequence[str], clock: Clock) -> AsyncIterator[FastAPI]:
    application = create_app(settings, plugin_modules=plugin_modules, clock=clock)
    async with application.router.lifespan_context(application):
        yield application


@pytest.fixture
def registry(app: FastAPI) -> PluginRegistry:
    reg: PluginRegistry = app.state.registry
    return reg


@pytest.fixture
async def client(app: FastAPI) -> AsyncIterator[httpx.AsyncClient]:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://zoro.test") as http:
        yield http


@pytest.fixture
async def db(registry: PluginRegistry) -> AsyncIterator[AsyncSession]:
    async with registry.service("session_factory")() as session:
        yield session


@pytest.fixture
def pair_device(registry: PluginRegistry, clock: Clock) -> PairDevice:
    """`await pair_device(name=..., platform=..., capabilities=[...])` -> a signed-in `PairedDevice`."""

    async def _pair(
        *,
        name: str = "Test iPhone",
        platform: DevicePlatform = DevicePlatform.IOS,
        capabilities: list[str] | None = None,
    ) -> PairedDevice:
        devices = registry.service("devices")
        sessions = registry.service("sessions")
        signer = DeviceSigner(name=name, platform=platform, now=clock.now)
        issued = await devices.create_pairing_code()
        record = await devices.pair(signer.pair_request(issued.code, capabilities))
        signer.device_id = record.id
        challenge = await sessions.create_challenge(record.id)
        token = await sessions.issue_token(signer.sign_auth(challenge.nonce))
        return PairedDevice(device_id=record.id, signer=signer, token=token.access_token)

    return _pair


@pytest.fixture
async def paired_device(pair_device: PairDevice) -> PairedDevice:
    return await pair_device()
