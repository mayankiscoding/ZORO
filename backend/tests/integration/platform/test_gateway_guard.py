"""Model gateway hardening: privacy-mode clamp, kill switch, `permitted`, locality, per-turn cost."""

from __future__ import annotations

from decimal import Decimal

import httpx
import pytest

from app.core.types import DataClass, Locality, PrivacyMode, TaskClass
from app.providers.config import StaticConfig
from app.providers.gateway import ModelGateway
from app.providers.guard import KILL_SWITCH_REASON, clamp_mode, stricter
from app.providers.resilience import RetryPolicy
from app.providers.types import ChatMessage, ChatRequest, EgressDenied
from app.providers.usage import MemoryUsageSink, UsageRecord
from tests.fakes.gateway import FakeGateway
from tests.providers.conftest import ENV, Recorder, gemini_text, make_config, openai_text

CLOUD = PrivacyMode.CLOUD_INTELLIGENCE
STRICT = PrivacyMode.STRICT_PRIVATE
PERSONAL = frozenset({DataClass.PERSONAL})


class ServerState:
    """A privacy_state double with the server mode, as `PrivacyStateService` exposes it."""

    def __init__(self, mode: PrivacyMode) -> None:
        self.mode = mode

    async def get_mode(self) -> PrivacyMode:
        return self.mode

    async def egress_overrides(self) -> tuple[bool, frozenset[DataClass]]:
        return False, frozenset()


class Switch:
    def __init__(self, on: bool) -> None:
        self.on = on

    async def is_on(self) -> bool:
        return self.on


def _handler(r: httpx.Request) -> httpx.Response:
    return {"gem.test": gemini_text("cloud"), "local.test": openai_text("local")}[r.url.host]


def gateway(
    server: PrivacyMode, *, killed: bool = False, usage: MemoryUsageSink | None = None
) -> tuple[ModelGateway, Recorder]:
    rec = Recorder(_handler)
    gw = ModelGateway(
        StaticConfig(make_config(), ENV),
        http=httpx.AsyncClient(transport=httpx.MockTransport(rec)),
        privacy_state=ServerState(server),
        kill_switch=Switch(killed),
        usage=usage or MemoryUsageSink(),
        retry=RetryPolicy(max_attempts=1),
    )
    return gw, rec


def chat(mode: PrivacyMode, turn_id: str = "turn_1") -> ChatRequest:
    return ChatRequest(
        task=TaskClass.ROUTINE_CHAT,
        messages=(ChatMessage(role="user", content="hello"),),
        data_classes=PERSONAL,
        privacy_mode=mode,
        turn_id=turn_id,
    )


def test_stricter_mode_table() -> None:
    assert stricter(CLOUD, CLOUD) is CLOUD
    assert stricter(CLOUD, STRICT) is STRICT
    assert stricter(STRICT, CLOUD) is STRICT


async def test_clamp_without_server_state_keeps_the_request() -> None:
    assert await clamp_mode(None, CLOUD) is CLOUD


async def test_request_cannot_loosen_a_strict_server() -> None:
    gw, rec = gateway(STRICT)
    resp = await gw.chat(chat(CLOUD))  # asks for cloud, server is strict: only the local model
    assert resp.model == "l-small"
    assert resp.locality is Locality.LOCAL and not resp.external
    assert rec.hosts() == ["local.test"]


async def test_request_may_tighten_a_cloud_server() -> None:
    gw, rec = gateway(CLOUD)
    resp = await gw.chat(chat(STRICT))
    assert resp.locality is Locality.LOCAL
    assert rec.hosts() == ["local.test"]


async def test_cloud_server_and_cloud_request_reach_external_with_locality() -> None:
    gw, rec = gateway(CLOUD)
    resp = await gw.chat(chat(CLOUD))
    assert resp.model == "g-flash"
    assert resp.locality is Locality.EXTERNAL and resp.external
    assert rec.hosts() == ["gem.test"]


async def test_kill_switch_refuses_every_external_model() -> None:
    gw, rec = gateway(CLOUD, killed=True)
    cands = await gw.candidates(TaskClass.ROUTINE_CHAT, PERSONAL, CLOUD, "chat")
    assert [c.model.id for c in cands] == ["l-small"]
    resp = await gw.chat(chat(CLOUD))
    assert resp.locality is Locality.LOCAL
    assert "gem.test" not in rec.hosts() and "oai.test" not in rec.hosts()


async def test_kill_switch_with_external_only_route_raises_egress_denied() -> None:
    gw, rec = gateway(CLOUD, killed=True)
    with pytest.raises(EgressDenied) as info:
        await gw.candidates(TaskClass.COMPLEX_REASONING, PERSONAL, CLOUD, "chat")
    assert set(info.value.reasons.values()) == {KILL_SWITCH_REASON}
    assert await gw.permitted(TaskClass.COMPLEX_REASONING, PERSONAL, CLOUD) is False
    assert rec.hosts() == []


async def test_permitted_reflects_policy_without_network() -> None:
    gw, rec = gateway(CLOUD)
    assert await gw.permitted(TaskClass.COMPLEX_REASONING, PERSONAL, CLOUD) is True
    assert await gw.permitted(TaskClass.COMPLEX_REASONING, PERSONAL, STRICT) is False
    assert await gw.permitted(TaskClass.ROUTINE_CHAT, frozenset({DataClass.SECRET}), CLOUD) is False
    assert rec.hosts() == []


async def test_stream_chunks_carry_locality() -> None:
    rec2 = Recorder(
        lambda r: httpx.Response(
            200,
            text='data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n',
            headers={"content-type": "text/event-stream"},
        )
    )
    gw = ModelGateway(
        StaticConfig(make_config(), ENV),
        http=httpx.AsyncClient(transport=httpx.MockTransport(rec2)),
        privacy_state=ServerState(STRICT),
        retry=RetryPolicy(max_attempts=1),
    )
    chunks = [c async for c in gw.stream(chat(CLOUD))]
    assert chunks and all(c.locality is Locality.LOCAL for c in chunks)


async def test_turn_cost_is_exact_and_scoped_to_the_turn() -> None:
    usage = MemoryUsageSink()
    gw, _ = gateway(CLOUD, usage=usage)
    await gw.chat(chat(CLOUD, "turn_a"))
    await usage.record(UsageRecord(provider="x", model="y", task="t", turn_id="turn_b", cost_micro_usd=7))
    cost_a = await gw.turn_cost_usd("turn_a")
    assert isinstance(cost_a, Decimal) and cost_a > 0
    assert await gw.turn_cost_usd("turn_b") == Decimal("0.000007")
    assert await gw.turn_cost_usd("missing") == Decimal(0)


async def test_fake_gateway_mirrors_permitted_and_cost() -> None:
    fake = FakeGateway(permit=lambda task, classes, mode: mode is CLOUD)
    assert await fake.permitted(TaskClass.ROUTINE_CHAT, PERSONAL, CLOUD) is True
    assert await fake.permitted(TaskClass.ROUTINE_CHAT, PERSONAL, STRICT) is False
    fake.turn_costs["t1"] = Decimal("0.01")
    assert await fake.turn_cost_usd("t1") == Decimal("0.01")
    assert await FakeGateway(permit=False).permitted(TaskClass.ROUTINE_CHAT, PERSONAL, CLOUD) is False
