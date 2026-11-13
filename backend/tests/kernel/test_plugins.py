"""Plugin loader, registry services, app factory with no plugins, CLI."""

from __future__ import annotations

import base64
import sys
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path

import httpx
import pytest
from fastapi import APIRouter, Depends, FastAPI, WebSocket
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app import cli
from app.api.deps import CurrentDevice, block_when_killed, require_device
from app.core.settings import Settings, get_settings
from app.core.types import AgentId, CapabilityStatus, PrivacyMode
from app.db.base import Base
from app.db.discovery import import_models, model_packages, module_exists
from app.main import create_app
from app.plugins import PLUGIN_MODULES, PluginError, PluginRegistry, build_kernel, load_plugins
from app.schemas.security import Capability
from app.tools.intents import IntentContext, IntentSpec
from tests.conftest import PairedDevice
from tests.fakes.devices import DeviceSigner
from tests.kernel.conftest import make_tool

REQUIRED_SERVICES = [
    "session_factory", "settings", "clock", "audit", "secrets", "objects", "tool_registry",
    "tool_executor", "approvals", "policy", "privacy_state", "capabilities",
]  # fmt: skip

OK_PLUGIN = """
from fastapi import APIRouter
from app.schemas.security import Capability

calls = []
router = APIRouter(prefix="/zplug")

@router.get("/ping")
async def ping() -> dict[str, str]:
    return {"pong": "yes"}

def register(reg):
    calls.append("register")
    reg.add_router(router)
    reg.add_permission("zplug.read", "Read zplug data", True)
    reg.add_capability(Capability(id="zplug.ping", title="Ping", domain="zplug", status="working_local"))
    reg.provide("zplug", {"ready": True})
    reg.add_startup(lambda: calls.append("startup"))
    async def stop():
        calls.append("shutdown")
    reg.add_shutdown(stop)
"""

MODELS = """
from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column
from app.db.base import Base

class ZplugThing(Base):
    __tablename__ = "zplug_things"
    __table_args__ = {"extend_existing": True}  # the test re-imports this module
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
"""


@pytest.fixture
def plugin_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    root = tmp_path / "plugins"
    packages = {
        "zplug_ok": {"plugin.py": OK_PLUGIN, "models.py": MODELS},
        "zplug_import_error": {"plugin.py": "raise RuntimeError('broken at import')\n"},
        "zplug_missing_dep": {
            "plugin.py": "import a_library_that_is_not_installed\n\ndef register(reg):\n    pass\n"
        },
        "zplug_register_error": {
            "plugin.py": "def register(reg):\n    raise ValueError('broken in register')\n"
        },
        "zplug_no_register": {"plugin.py": "x = 1\n"},
        "zplug_empty": {},
    }
    for package, files in packages.items():
        (root / package).mkdir(parents=True)
        (root / package / "__init__.py").write_text("")
        for name, source in files.items():
            (root / package / name).write_text(source)
    monkeypatch.syspath_prepend(str(root))
    yield root
    for name in [m for m in sys.modules if m.startswith("zplug_")]:
        del sys.modules[name]


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        _env_file=None, env="test", database_url=f"sqlite+aiosqlite:///{tmp_path / 'p.db'}",
        object_dir=tmp_path / "objects", local_dir=tmp_path / "local",
    )  # fmt: skip


# ---------------------------------------------------------------- loader


def test_plugin_module_order_is_the_contract() -> None:
    assert PLUGIN_MODULES == (
        "app.providers.plugin", "app.agents.plugin", "app.orchestrator.plugin", "app.mcp.plugin",
        "app.devices.plugin", "app.memory.plugin", "app.documents.plugin", "app.finance.plugin",
        "app.investment.plugin", "app.shopping.plugin", "app.research.plugin", "app.fitness.plugin",
        "app.vision.plugin", "app.voice.plugin", "app.music.plugin", "app.communications.plugin",
        "app.automation.plugin",
    )  # fmt: skip
    assert model_packages()[:3] == ("app.security", "app.tools", "app.providers")
    assert model_packages(("x.y.plugin", "x.z.plugin")) == ("app.security", "app.tools", "x.y", "x.z")


def test_missing_plugins_are_skipped_with_a_log_line(
    tmp_path: Path, plugin_dir: Path, caplog: pytest.LogCaptureFixture
) -> None:
    reg = build_kernel(_settings(tmp_path))
    with caplog.at_level("INFO", logger="app.plugins"):
        loaded = load_plugins(reg, ["zplug_absent.plugin", "zplug_empty.plugin", "zplug_ok.plugin"])
    assert loaded == ["zplug_ok.plugin"]
    assert reg.skipped_plugins == ["zplug_absent.plugin", "zplug_empty.plugin"]
    skipped = [r for r in caplog.records if r.getMessage() == "plugin not present, skipped"]
    assert [r.plugin for r in skipped] == ["zplug_absent.plugin", "zplug_empty.plugin"]  # type: ignore[attr-defined]
    assert module_exists("zplug_ok.plugin") and not module_exists("zplug_ok.nothing")
    assert not module_exists("zplug_absent.deep.plugin")


@pytest.mark.parametrize(
    ("module", "error", "match"),
    [
        ("zplug_import_error.plugin", RuntimeError, "broken at import"),
        ("zplug_missing_dep.plugin", ModuleNotFoundError, "a_library_that_is_not_installed"),
        ("zplug_register_error.plugin", ValueError, "broken in register"),
        ("zplug_no_register.plugin", PluginError, "no register"),
    ],
)
def test_errors_inside_an_existing_plugin_propagate(
    tmp_path: Path, plugin_dir: Path, module: str, error: type[Exception], match: str
) -> None:
    reg = build_kernel(_settings(tmp_path))
    with pytest.raises(error, match=match):
        load_plugins(reg, ["zplug_absent.plugin", module])
    with pytest.raises(error, match=match):
        create_app(_settings(tmp_path), plugin_modules=[module])


async def test_plugin_contributions_reach_the_app(tmp_path: Path, plugin_dir: Path) -> None:
    app = create_app(_settings(tmp_path), plugin_modules=["zplug_absent.plugin", "zplug_ok.plugin"])
    reg: PluginRegistry = app.state.registry
    plugin = sys.modules["zplug_ok.plugin"]
    assert plugin.calls == ["register"]
    assert "zplug_things" in Base.metadata.tables  # models discovered by package name
    async with app.router.lifespan_context(app):
        assert plugin.calls == ["register", "startup"]
        assert reg.service("zplug") == {"ready": True}
        assert await reg.service("permissions").is_granted("zplug.read") is True
        assert [c.id for c in reg.capabilities.all(domain="zplug")] == ["zplug.ping"]
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as http:
            assert (await http.get("/v1/zplug/ping")).json() == {"pong": "yes"}  # mounted under /v1
            await reg.service("kill_switch").set(True)
            closed = await http.get("/v1/zplug/ping")
            assert closed.status_code == 503 and closed.json()["code"] == "kill_switch_active"
    assert plugin.calls == ["register", "startup", "shutdown"]


def test_import_models_skips_packages_without_models(plugin_dir: Path) -> None:
    assert import_models(["zplug_ok", "zplug_empty", "zplug_absent"]) == ["zplug_ok.models"]
    assert import_models(["app.security", "app.tools"]) == ["app.security.models", "app.tools.models"]


# ---------------------------------------------------------------- registry


def test_kernel_services_and_registry_rules(registry: PluginRegistry) -> None:
    for name in REQUIRED_SERVICES:
        assert registry.service(name) is not None, name
    assert registry.service("tool_registry") is registry.tools
    assert registry.service("capabilities") is registry.capabilities
    with pytest.raises(PluginError, match="no service named 'gateway'"):
        registry.service("gateway")
    with pytest.raises(LookupError):
        registry.service("gateway")
    registry.provide("gateway", object())
    with pytest.raises(PluginError, match="already provided"):
        registry.provide("gateway", object())
    with pytest.raises(PluginError):
        registry.provide("settings", object())  # a plugin cannot replace a kernel service

    registry.add_tool(make_tool())
    assert "test.echo" in registry.service("tool_registry")
    intent = IntentSpec(
        name="test.echo_intent",
        agent=AgentId.PERSONAL_ASSISTANT,
        tool="test.echo",
        keywords={"en": ["echo"], "hi": ["दोहराओ"], "hinglish": ["dohrao"]},
        extract=lambda text, ctx: {"text": text} if "echo" in text else None,
        priority=5,
    )
    registry.add_intent(intent)
    ctx = IntentContext(lang="en", now=datetime.now(UTC))
    assert registry.intents.all()[0].extract("echo this", ctx) == {"text": "echo this"}
    assert registry.intents.all()[0].extract("something else", ctx) is None
    with pytest.raises(ValueError):
        registry.add_intent(intent)
    with pytest.raises(ValueError):
        registry.add_permission("Bad Key", "x", False)

    registry.add_capability(
        Capability(id="a.static", title="A", domain="a", status=CapabilityStatus.WORKING_LOCAL)
    )
    registry.add_capability(
        lambda: [
            Capability(id="a.dynamic", title="D", domain="a", status=CapabilityStatus.REQUIRES_CREDENTIALS)
        ]
    )
    assert [c.id for c in registry.capabilities.all(domain="a")] == ["a.dynamic", "a.static"]
    with pytest.raises(PluginError):
        registry.add_capability(
            Capability(id="a.static", title="A", domain="a", status=CapabilityStatus.UNAVAILABLE)
        )

    ctx_tool = registry.tool_context(
        turn_id="t1", agent=AgentId.FINANCE, privacy_mode=PrivacyMode.STRICT_PRIVATE
    )
    assert ctx_tool.gateway is registry.service("gateway")
    assert ctx_tool.db is registry.service("session_factory")
    assert ctx_tool.now() == registry.service("clock").now()
    assert ctx_tool.tainted is False and ctx_tool.user_initiated is False


async def test_tool_context_emits_only_when_a_stream_is_attached(registry: PluginRegistry) -> None:
    seen: list[object] = []

    async def emitter(event: object) -> None:
        seen.append(event)

    silent = registry.tool_context(turn_id="t1", agent=AgentId.FINANCE)
    await silent.emit({"type": "text_delta"})
    loud = registry.tool_context(turn_id="t1", agent=AgentId.FINANCE, emitter=emitter)
    await loud.emit({"type": "text_delta"})
    assert seen == [{"type": "text_delta"}]


async def test_plugin_router_can_use_kernel_dependencies(
    app: FastAPI, client: httpx.AsyncClient, paired_device: PairedDevice
) -> None:
    router = APIRouter(prefix="/whoami")

    @router.get("")
    async def whoami(device: CurrentDevice) -> dict[str, str]:
        return {"device_id": device.device_id, "platform": device.platform.value}

    app.include_router(router, prefix="/v1")
    assert require_device is not None
    assert (await client.get("/v1/whoami")).status_code == 401
    me = await client.get("/v1/whoami", headers=paired_device.headers)
    assert me.json() == {"device_id": paired_device.device_id, "platform": "ios"}


# ---------------------------------------------------------------- app factory with no plugins


async def test_create_app_starts_with_zero_plugins(tmp_path: Path) -> None:
    absent = [f"zoro_not_there_{i}.plugin" for i in range(3)]
    for modules in ([], absent):
        app = create_app(_settings(tmp_path), plugin_modules=modules)
        reg: PluginRegistry = app.state.registry
        assert reg.loaded_plugins == [] and reg.skipped_plugins == modules
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as http:
                assert (await http.get("/healthz")).json()["status"] == "ok"
                assert (await http.get("/v1/capabilities")).status_code == 401
            assert len(reg.tools) == 0
            assert await reg.service("privacy_state").get_mode() is PrivacyMode.STRICT_PRIVATE


async def test_default_privacy_mode_comes_from_settings(tmp_path: Path) -> None:
    settings = _settings(tmp_path).model_copy(update={"default_privacy_mode": PrivacyMode.CLOUD_INTELLIGENCE})
    app = create_app(settings, plugin_modules=[])
    async with app.router.lifespan_context(app):
        privacy = app.state.registry.service("privacy_state")
        assert await privacy.get_mode() is PrivacyMode.CLOUD_INTELLIGENCE
        assert await privacy.effective_mode(PrivacyMode.STRICT_PRIVATE) is PrivacyMode.STRICT_PRIVATE
        await privacy.set_mode(PrivacyMode.STRICT_PRIVATE)
        # a client can ask for stricter, never for looser
        assert await privacy.effective_mode(PrivacyMode.CLOUD_INTELLIGENCE) is PrivacyMode.STRICT_PRIVATE


# ---------------------------------------------------------------- CLI


def test_cli_commands(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ZORO_ENV", "test")
    monkeypatch.setenv("ZORO_DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'cli.db'}")
    monkeypatch.setenv("ZORO_OBJECT_DIR", str(tmp_path / "objects"))
    monkeypatch.setenv("ZORO_SECRET_KEY", "k" * 48)
    monkeypatch.setenv("ZORO_DATA_KEY", base64.b64encode(bytes(range(32))).decode())
    monkeypatch.chdir(tmp_path)  # no .env file here
    get_settings.cache_clear()
    try:
        assert cli.main(["gen-keys"]) == 0
        out = capsys.readouterr().out
        keys = dict(line.split("=", 1) for line in out.strip().splitlines())
        assert len(base64.b64decode(keys["ZORO_DATA_KEY"])) == 32 and len(keys["ZORO_SECRET_KEY"]) >= 48
        assert cli.main(["gen-keys"]) == 0
        assert keys["ZORO_SECRET_KEY"] not in capsys.readouterr().out  # fresh every time

        assert cli.main(["init-db"]) == 0
        out = capsys.readouterr().out
        for table in ("devices", "audit_log", "approvals", "integration_credentials", "kernel_tool_calls"):
            assert table in out

        assert cli.main(["pairing-code"]) == 0
        out = capsys.readouterr().out
        code = out.split("Pairing code:")[1].split()[0]
        assert len(code) == 9 and code[4] == "-"
        assert "10 minutes" in out

        assert cli.main(["verify-audit"]) == 0
        assert "Audit chain intact: 1 records" in capsys.readouterr().out

        import sqlite3

        with sqlite3.connect(tmp_path / "cli.db") as raw:
            raw.execute("UPDATE audit_log SET actor = 'intruder'")
        assert cli.main(["verify-audit"]) == 1
        assert "BROKEN" in capsys.readouterr().out
        with pytest.raises(SystemExit):
            cli.main(["no-such-command"])
    finally:
        get_settings.cache_clear()


# ---------------------------------------------------------------- WebSocket routes use the same dependencies


def test_websocket_routes_authenticate_and_obey_the_kill_switch(tmp_path: Path) -> None:
    router = APIRouter(prefix="/devices")

    @router.websocket("/channel")
    async def channel(websocket: WebSocket, device: CurrentDevice) -> None:
        await websocket.accept()
        await websocket.send_json({"device_id": device.device_id})
        await websocket.close()

    app = create_app(_settings(tmp_path), plugin_modules=[])
    reg: PluginRegistry = app.state.registry
    # mounted the way create_app mounts plugin routers
    app.include_router(router, prefix="/v1", dependencies=[Depends(block_when_killed)])
    signer = DeviceSigner()

    async def sign_in() -> str:
        if signer.device_id is None:
            issued = await reg.service("devices").create_pairing_code()
            record = await reg.service("devices").pair(signer.pair_request(issued.code))
            signer.device_id = record.id
        challenge = await reg.service("sessions").create_challenge(signer.device_id)
        token = await reg.service("sessions").issue_token(signer.sign_auth(challenge.nonce))
        return str(token.access_token)

    with TestClient(app) as http:
        assert http.portal is not None
        headers = {"Authorization": f"Bearer {http.portal.call(sign_in)}"}
        with http.websocket_connect("/v1/devices/channel", headers=headers) as socket:
            assert socket.receive_json() == {"device_id": signer.device_id}

        with pytest.raises(WebSocketDisconnect) as refused, http.websocket_connect("/v1/devices/channel"):
            pass
        assert refused.value.code == 1008 and refused.value.reason == "unauthorized"

        http.portal.call(lambda: reg.service("kill_switch").set(True))
        headers = {"Authorization": f"Bearer {http.portal.call(sign_in)}"}  # sessions ended; sign in again
        with (
            pytest.raises(WebSocketDisconnect) as killed,
            http.websocket_connect("/v1/devices/channel", headers=headers),
        ):
            pass
        assert killed.value.code == 1008 and killed.value.reason == "kill_switch_active"
