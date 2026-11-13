from __future__ import annotations

import sys
import types
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx
import pytest
import yaml
from fastapi import FastAPI, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine
from sqlalchemy.pool import StaticPool

from app.core.types import CapabilityStatus, DataClass, PrivacyMode, TaskClass
from app.providers import plugin
from app.providers.api import build_router
from app.providers.config import StaticConfig
from app.providers.gateway import ModelGateway
from app.providers.models import UsageEvent
from app.providers.types import ChatMessage, ChatRequest, NoPermittedModel
from app.providers.usage import DbUsageSink, UsageRecord, cost_summary
from tests.fakes.gateway import FakeGateway
from tests.providers.conftest import ENV, Grants, make_config, raw_config


@pytest.fixture
async def engine() -> AsyncIterator[AsyncEngine]:
    eng = create_async_engine("sqlite+aiosqlite://", poolclass=StaticPool)
    async with eng.begin() as conn:
        await conn.run_sync(lambda c: UsageEvent.__table__.create(c))
    yield eng
    await eng.dispose()


def _ev(
    model: str, day: int, cost: int, *, error: bool = False, agent: str | None = "finance"
) -> UsageRecord:
    return UsageRecord(
        provider="gem" if model.startswith("g") else "oai",
        model=model,
        task="routine_chat",
        agent=agent,
        input_tokens=100,
        output_tokens=10,
        latency_ms=200 if not error else 400,
        cost_micro_usd=cost,
        error=error,
        error_kind="timeout" if error else None,
        ts=datetime(2026, 11, day, 9, 30, tzinfo=UTC),
    )


async def _seed(engine: AsyncEngine) -> async_sessionmaker[Any]:
    sf = async_sessionmaker(engine, expire_on_commit=False)
    sink = DbUsageSink(sf)
    for ev in [
        _ev("g-flash", 12, 1500),
        _ev("g-flash", 13, 250, error=True),
        _ev("o-mini", 13, 1, agent=None),
    ]:
        await sink.record(ev)
    return sf


async def test_cost_summary_grouping(engine: AsyncEngine) -> None:
    sf = await _seed(engine)
    by_model = await cost_summary(sf, "model")
    assert by_model.total_cost_usd == Decimal("0.001751")
    rows = {r.key: r for r in by_model.items}
    assert rows["g-flash"].requests == 2 and rows["g-flash"].error_rate == 0.5
    assert rows["g-flash"].cost_usd == Decimal("0.00175") and rows["g-flash"].avg_latency_ms == 300.0
    by_day = await cost_summary(sf, "day")
    assert [r.key for r in by_day.items] == ["2026-11-12", "2026-11-13"]
    by_agent = await cost_summary(sf, "agent")
    assert {r.key for r in by_agent.items} == {"finance", "none"}
    since = await cost_summary(sf, "provider", since=datetime(2026, 11, 13, tzinfo=UTC))
    assert {r.key: r.requests for r in since.items} == {"gem": 1, "oai": 1}


async def test_gateway_writes_usage_rows(engine: AsyncEngine) -> None:
    sf = async_sessionmaker(engine, expire_on_commit=False)

    def handler(r: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "candidates": [{"content": {"parts": [{"text": "ok"}]}}],
                "usageMetadata": {"promptTokenCount": 1000, "candidatesTokenCount": 200},
            },
        )

    gw = ModelGateway(
        StaticConfig(make_config(), ENV),
        http=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
        privacy_state=Grants(),
        usage=DbUsageSink(sf),
    )
    await gw.chat(
        ChatRequest(
            task=TaskClass.ROUTINE_CHAT,
            messages=(ChatMessage(role="user", content="hi"),),
            data_classes=frozenset({DataClass.PUBLIC}),
            privacy_mode=PrivacyMode.CLOUD_INTELLIGENCE,
        )
    )
    summary = await cost_summary(sf, "model")
    assert summary.items[0].key == "g-flash" and summary.total_cost_usd == Decimal("0.0015")


def _device_guard(request: Request) -> str:
    if request.headers.get("authorization") != "Bearer dev":
        raise HTTPException(401, "no device")
    return "dev_1"


async def test_api_routes(engine: AsyncEngine) -> None:
    sf = await _seed(engine)
    gw = ModelGateway(StaticConfig(make_config(), {"GEM_KEY": "k"}), privacy_state=Grants())
    app = FastAPI()
    app.include_router(build_router(gw, sf, _device_guard), prefix="/v1")
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
        assert (await client.get("/v1/costs/summary")).status_code == 401
        auth = {"authorization": "Bearer dev"}
        resp = await client.get("/v1/costs/summary", params={"group_by": "provider"}, headers=auth)
        assert resp.status_code == 200
        body = resp.json()
        assert body["group_by"] == "provider" and Decimal(body["total_cost_usd"]) == Decimal("0.001751")
        assert (
            await client.get("/v1/costs/summary", params={"group_by": "bogus"}, headers=auth)
        ).status_code == 422
        routes = (
            await client.get("/v1/models/routes", params={"privacy_mode": "cloud_intelligence"}, headers=auth)
        ).json()
        chat = next(r for r in routes if r["task"] == "routine_chat")
        assert chat["active_model"] == "g-flash" and chat["models"] == ["g-flash", "o-mini", "l-small"]
    await gw.aclose()


class FakeRegistry:
    def __init__(self, services: dict[str, Any]) -> None:
        self.services = services
        self.provided: dict[str, Any] = {}
        self.routers: list[Any] = []
        self.capabilities: list[Any] = []
        self.shutdown: list[Any] = []

    def service(self, name: str) -> Any:
        return self.services[name]

    def provide(self, name: str, value: Any) -> None:
        self.provided[name] = value

    def add_router(self, router: Any) -> None:
        self.routers.append(router)

    def add_capability(self, cap: Any) -> None:
        self.capabilities.append(cap)

    def add_shutdown(self, fn: Any) -> None:
        self.shutdown.append(fn)


async def test_plugin_register(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (tmp_path / "models.yaml").write_text(yaml.safe_dump(raw_config()), encoding="utf-8")
    deps = types.ModuleType("app.api.deps")
    deps.require_device = _device_guard  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "app.api.deps", deps)
    monkeypatch.setenv("GEM_KEY", "k")
    monkeypatch.delenv("OAI_KEY", raising=False)
    monkeypatch.delenv("LOCAL_URL", raising=False)
    settings = types.SimpleNamespace(config_dir=str(tmp_path))
    reg = FakeRegistry({"settings": settings, "session_factory": object(), "privacy_state": Grants()})
    plugin.register(reg)
    assert isinstance(reg.provided["gateway"], ModelGateway)
    assert len(reg.routers) == 1 and len(reg.shutdown) == 1
    caps = {c.id: c for c in reg.capabilities}
    assert caps["models.gem"].status is CapabilityStatus.WORKING_INTEGRATION
    assert caps["models.oai"].status is CapabilityStatus.REQUIRES_CREDENTIALS
    assert caps["models.oai"].requires == ["OAI_KEY"]
    assert caps["models.local"].status is CapabilityStatus.REQUIRES_CREDENTIALS
    assert all("reachability is not checked" in c.note or "Disabled" in c.note for c in caps.values())
    await reg.shutdown[0]()


def test_config_path_defaults_to_repo_config() -> None:
    assert plugin.config_path(None, {}).parts[-2:] == ("config", "models.yaml")
    assert plugin.config_path(None, {"ZORO_CONFIG_DIR": "/x"}) == Path("/x/models.yaml")


async def test_fake_gateway_scripts_and_records() -> None:
    gw = FakeGateway(["hello there", {"intent": "pay"}, NoPermittedModel(TaskClass.ROUTINE_CHAT)])
    request = ChatRequest(task=TaskClass.ROUTINE_CHAT, messages=(ChatMessage(role="user", content="x"),))
    assert (await gw.chat(request)).text == "hello there"
    assert (await gw.chat(request)).parsed == {"intent": "pay"}
    with pytest.raises(NoPermittedModel):
        await gw.chat(request)
    assert len(gw.requests) == 3
    gw.push("streamed reply")
    chunks = [c async for c in gw.stream(request)]
    assert "".join(c.delta for c in chunks).strip() == "streamed reply" and chunks[-1].done
    vecs = await gw.embed(["a"], frozenset({DataClass.PUBLIC}))
    assert len(vecs[0]) == 256
