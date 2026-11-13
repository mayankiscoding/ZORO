from __future__ import annotations

import json
from decimal import Decimal

import httpx
import pytest

from app.core.types import AgentId, DataClass, Locality, PrivacyMode, TaskClass
from app.providers.config import parse_config
from app.providers.embedding import LOCAL_HASH_MODEL_ID, local_hash_embed
from app.providers.resilience import BreakerState, RetryPolicy
from app.providers.types import ChatMessage, ChatRequest, EgressDenied, NoPermittedModel, ProviderError
from app.providers.usage import cost_micro_usd
from tests.providers.conftest import (
    ENV,
    Clock,
    Grants,
    Sleeps,
    build_gateway,
    gemini_text,
    make_config,
    openai_text,
    raw_config,
)

CLOUD = PrivacyMode.CLOUD_INTELLIGENCE
STRICT = PrivacyMode.STRICT_PRIVATE
PII = "My PAN is ABCPE1234F and phone 9876543210"


def req(
    content: str = "hello",
    *,
    mode: PrivacyMode = CLOUD,
    classes: frozenset[DataClass] = frozenset({DataClass.PERSONAL}),
    task: TaskClass = TaskClass.ROUTINE_CHAT,
    **kw: object,
) -> ChatRequest:
    return ChatRequest(
        task=task,
        messages=(ChatMessage(role="system", content="sys"), ChatMessage(role="user", content=content)),
        data_classes=classes,
        privacy_mode=mode,
        agent=AgentId.PERSONAL_ASSISTANT,
        turn_id="turn_1",
        **kw,  # type: ignore[arg-type]
    )


def by_host(
    gem: httpx.Response | None = None, oai: httpx.Response | None = None, local: httpx.Response | None = None
):  # type: ignore[no-untyped-def]
    def handler(r: httpx.Request) -> httpx.Response:
        resp = {"gem.test": gem, "oai.test": oai, "local.test": local}[r.url.host]
        assert resp is not None, f"unexpected call to {r.url.host}"
        return resp

    return handler


# ---- privacy --------------------------------------------------------------------------------------


async def test_strict_private_makes_zero_external_calls_and_raises() -> None:
    gw, rec, _ = build_gateway(by_host(), env={"GEM_KEY": "k", "OAI_KEY": "k"}, grants=Grants())
    with pytest.raises(EgressDenied) as ei:
        await gw.chat(req(mode=STRICT, classes=frozenset({DataClass.PUBLIC})))
    assert rec.requests == []
    assert ei.value.reasons["g-flash"] == "strict_private_mode"
    assert isinstance(ei.value, NoPermittedModel)


async def test_strict_private_uses_local_model_only() -> None:
    gw, rec, _ = build_gateway(by_host(local=openai_text("local hi")), grants=Grants())
    resp = await gw.chat(req(PII, mode=STRICT, classes=frozenset({DataClass.FINANCIAL})))
    assert resp.text == "local hi" and resp.provider == "local"
    assert rec.hosts() == ["local.test"]
    assert PII in json.dumps(rec.bodies()[0], ensure_ascii=False)  # private locality: no redaction


async def test_secret_never_sent_anywhere() -> None:
    gw, rec, _ = build_gateway(by_host(), grants=Grants(frozenset(DataClass)))
    with pytest.raises(NoPermittedModel):
        await gw.chat(req(classes=frozenset({DataClass.SECRET})))
    assert rec.requests == []


async def test_without_privacy_state_external_is_refused_in_cloud_mode() -> None:
    gw, rec, _ = build_gateway(by_host(local=openai_text("ok")), grants=None)
    resp = await gw.chat(req(classes=frozenset({DataClass.PUBLIC})))
    assert resp.provider == "local"
    assert rec.hosts() == ["local.test"]


async def test_cloud_mode_redacts_personal_data() -> None:
    gw, rec, _ = build_gateway(by_host(gem=gemini_text("ok")), grants=Grants())
    await gw.chat(req(PII))
    sent = json.dumps(rec.bodies()[0])
    assert "ABCPE1234F" not in sent and "9876543210" not in sent
    assert "[redacted:pan]" in sent and "[redacted:phone]" in sent


async def test_cloud_mode_public_only_is_not_redacted() -> None:
    gw, rec, _ = build_gateway(by_host(gem=gemini_text("ok")), grants=Grants())
    await gw.chat(req("Call 9876543210 for the shop", classes=frozenset({DataClass.PUBLIC})))
    assert "9876543210" in json.dumps(rec.bodies()[0])


async def test_ungranted_class_skips_provider_and_falls_to_permitted_one() -> None:
    # Owner granted financial; oai's provider ceiling is public+personal, gem allows financial.
    gw, _rec, _ = build_gateway(
        by_host(gem=gemini_text("g")), grants=Grants(frozenset({DataClass.FINANCIAL}))
    )
    resp = await gw.chat(req(classes=frozenset({DataClass.FINANCIAL})))
    assert resp.provider == "gem"
    gw2, rec2, _ = build_gateway(by_host(local=openai_text("l")), grants=Grants())  # financial not granted
    assert (await gw2.chat(req(classes=frozenset({DataClass.FINANCIAL})))).provider == "local"
    assert rec2.hosts() == ["local.test"]


async def test_missing_keys_mean_no_permitted_model() -> None:
    gw, rec, _ = build_gateway(by_host(), env={}, grants=Grants())
    with pytest.raises(NoPermittedModel) as ei:
        await gw.chat(req())
    assert not isinstance(ei.value, EgressDenied)
    assert ei.value.reasons["g-flash"] == "provider_disabled:missing_env:GEM_KEY"
    assert rec.requests == []


# ---- fallback, retry, breaker ---------------------------------------------------------------------


async def test_fallback_on_5xx_after_retry_with_backoff(sleeps: Sleeps) -> None:
    gw, rec, usage = build_gateway(
        by_host(gem=httpx.Response(503), oai=openai_text("from oai")), grants=Grants(), sleeps=sleeps
    )
    resp = await gw.chat(req())
    assert resp.text == "from oai" and resp.model == "o-mini"
    assert rec.hosts() == ["gem.test", "gem.test", "oai.test"]
    assert sleeps.calls == [pytest.approx(0.25)]  # base 0.25 * 2**0 * (0.5 + 0.5)
    assert [e.error for e in usage.events] == [True, True, False]
    assert usage.events[0].error_kind == "unavailable"


async def test_fallback_on_429_with_long_retry_after_cools_model_down(sleeps: Sleeps, clock: Clock) -> None:
    gw, rec, _ = build_gateway(
        by_host(gem=httpx.Response(429, headers={"retry-after": "60"}), oai=openai_text("oai")),
        grants=Grants(),
        sleeps=sleeps,
        clock=clock,
    )
    assert (await gw.chat(req())).model == "o-mini"
    assert rec.hosts() == ["gem.test", "oai.test"]
    assert sleeps.calls == []
    await gw.chat(req())  # g-flash still cooling down: not called
    assert rec.hosts()[-1] == "oai.test" and rec.hosts().count("gem.test") == 1
    clock.now += 61
    gw2_calls = len(rec.requests)
    await gw.chat(req())
    assert rec.requests[gw2_calls].url.host == "gem.test"


async def test_429_with_short_retry_after_is_waited_out(sleeps: Sleeps) -> None:
    responses = iter([httpx.Response(429, headers={"retry-after": "1"}), gemini_text("second try")])
    gw, _rec, _ = build_gateway(lambda r: next(responses), grants=Grants(), sleeps=sleeps)
    resp = await gw.chat(req())
    assert resp.text == "second try"
    assert sleeps.calls == [1.0]


async def test_fallback_on_timeout() -> None:
    def handler(r: httpx.Request) -> httpx.Response:
        if r.url.host == "gem.test":
            raise httpx.ConnectTimeout("slow", request=r)
        return openai_text("oai")

    gw, _rec, usage = build_gateway(handler, grants=Grants())
    assert (await gw.chat(req())).model == "o-mini"
    assert usage.events[0].error_kind == "timeout"


async def test_auth_error_falls_back_without_retry(sleeps: Sleeps) -> None:
    gw, rec, _ = build_gateway(
        by_host(gem=httpx.Response(401), oai=openai_text("oai")), grants=Grants(), sleeps=sleeps
    )
    assert (await gw.chat(req())).model == "o-mini"
    assert rec.hosts() == ["gem.test", "oai.test"] and sleeps.calls == []


async def test_breaker_opens_then_half_opens(clock: Clock) -> None:
    state = {"gem_ok": False}

    def handler(r: httpx.Request) -> httpx.Response:
        if r.url.host == "gem.test":
            return gemini_text("gem back") if state["gem_ok"] else httpx.Response(500)
        return openai_text("oai")

    gw, rec, _ = build_gateway(handler, grants=Grants(), clock=clock, retry=RetryPolicy(max_attempts=1))
    for _ in range(3):  # threshold 3
        await gw.chat(req())
    assert gw.breaker("g-flash").state is BreakerState.OPEN
    before = len(rec.requests)
    await gw.chat(req())
    assert [r.url.host for r in rec.requests[before:]] == ["oai.test"]  # open: skipped
    clock.now += 30
    assert gw.breaker("g-flash").state is BreakerState.HALF_OPEN
    state["gem_ok"] = True
    resp = await gw.chat(req())
    assert resp.text == "gem back"
    assert gw.breaker("g-flash").state is BreakerState.CLOSED


async def test_all_candidates_fail_raises_provider_error() -> None:
    gw, _, _ = build_gateway(
        by_host(gem=httpx.Response(500), oai=httpx.Response(502), local=httpx.Response(500)), grants=Grants()
    )
    with pytest.raises(ProviderError) as ei:
        await gw.chat(req())
    assert ei.value.kind == "unavailable"


async def test_blocked_is_not_retried_elsewhere() -> None:
    blocked = httpx.Response(200, json={"promptFeedback": {"blockReason": "SAFETY"}})
    gw, rec, _ = build_gateway(by_host(gem=blocked, oai=openai_text("x")), grants=Grants())
    with pytest.raises(ProviderError) as ei:
        await gw.chat(req())
    assert ei.value.kind == "blocked" and rec.hosts() == ["gem.test"]


# ---- structured output, trimming, usage ---------------------------------------------------------


async def test_structured_output_parsed_and_invalid_json_falls_back() -> None:
    schema = {"type": "object", "properties": {"intent": {"type": "string"}}}
    gw, _, _ = build_gateway(by_host(gem=gemini_text('{"intent": "pay_bill"}')), grants=Grants())
    assert (await gw.chat(req(response_schema=schema))).parsed == {"intent": "pay_bill"}
    gw2, rec2, _ = build_gateway(
        by_host(gem=gemini_text("not json"), oai=openai_text('{"intent": "x"}')), grants=Grants()
    )
    assert (await gw2.chat(req(response_schema=schema))).parsed == {"intent": "x"}
    assert rec2.hosts() == ["gem.test", "oai.test"]


async def test_context_trimmed_to_window() -> None:
    raw = raw_config()
    for m in raw["models"]:
        m["context_window"] = 1500
    gw, rec, _ = build_gateway(by_host(gem=gemini_text("ok")), grants=Grants(), config=parse_config(raw))
    history = tuple(
        ChatMessage(role=r, content=f"turn {i} " + "x" * 600) for i, r in enumerate(["user", "assistant"] * 4)
    )
    request = ChatRequest(
        task=TaskClass.ROUTINE_CHAT,
        messages=(
            ChatMessage(role="system", content="keep me"),
            *history,
            ChatMessage(role="user", content="latest"),
        ),
        data_classes=frozenset({DataClass.PUBLIC}),
        privacy_mode=CLOUD,
        max_output_tokens=200,
    )
    await gw.chat(request)
    body = rec.bodies()[0]
    assert body["systemInstruction"]["parts"][0]["text"] == "keep me"
    texts = [p["text"] for c in body["contents"] for p in c["parts"]]
    assert texts[-1] == "latest"
    assert len(texts) < 9 and not any(t.startswith("turn 0 ") for t in texts)


async def test_usage_event_and_cost(clock: Clock) -> None:
    gw, _, usage = build_gateway(
        by_host(gem=gemini_text("ok", tin=1000, tout=200)), grants=Grants(), clock=clock
    )
    await gw.chat(req())
    ev = usage.events[0]
    assert (ev.provider, ev.model, ev.task, ev.agent, ev.turn_id) == (
        "gem",
        "g-flash",
        "routine_chat",
        "personal_assistant",
        "turn_1",
    )
    # 1000 * 0.75 + 200 * 3.75 = 1500 micro-USD
    assert ev.cost_micro_usd == 1500 and not ev.error


def test_cost_maths_exact_and_rounded() -> None:
    model = make_config().model("o-mini")  # 0.10 in / 0.50 out per 1M
    assert cost_micro_usd(model, 3, 1) == 1  # 0.3 + 0.5 = 0.8 -> 1 (half up)
    assert cost_micro_usd(model, 1_000_000, 1_000_000) == 600_000
    assert Decimal(cost_micro_usd(model, 1_000_000, 0)) / Decimal(1_000_000) == Decimal("0.1")


# ---- streaming ----------------------------------------------------------------------------------


async def test_stream_falls_back_before_first_chunk() -> None:
    sse = (
        "".join(
            f"data: {json.dumps(e)}\n\n"
            for e in [
                {"choices": [{"delta": {"content": "hi"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
            ]
        )
        + "data: [DONE]\n\n"
    )
    gw, rec, usage = build_gateway(
        by_host(gem=httpx.Response(503), oai=httpx.Response(200, content=sse.encode())), grants=Grants()
    )
    chunks = [c async for c in gw.stream(req())]
    assert "".join(c.delta for c in chunks) == "hi" and chunks[-1].done
    assert rec.hosts() == ["gem.test", "gem.test", "oai.test"]
    assert usage.events[-1].model == "o-mini" and not usage.events[-1].error


async def test_stream_strict_private_zero_calls() -> None:
    gw, rec, _ = build_gateway(by_host(), env={"GEM_KEY": "k"}, grants=Grants())
    with pytest.raises(NoPermittedModel):
        _ = [c async for c in gw.stream(req(mode=STRICT))]
    assert rec.requests == []


# ---- embeddings, route info, health -------------------------------------------------------------


async def test_embed_strict_uses_local_hash_with_zero_calls() -> None:
    gw, rec, _ = build_gateway(by_host(), grants=Grants())
    result = await gw.embed_with_model(["bijli bill"], frozenset({DataClass.PERSONAL}), STRICT)
    assert result.model == LOCAL_HASH_MODEL_ID and result.dims == 256
    assert [list(v) for v in result.vectors] == local_hash_embed(["bijli bill"])
    assert rec.requests == []


async def test_embed_cloud_uses_permitted_model_and_redacts() -> None:
    resp = httpx.Response(200, json={"embeddings": [{"values": [0.5, 0.5]}]})
    gw, rec, _ = build_gateway(by_host(gem=resp), grants=Grants())
    vecs = await gw.embed([PII], frozenset({DataClass.PERSONAL}), CLOUD)
    assert vecs == [[0.5, 0.5]]
    assert "ABCPE1234F" not in json.dumps(rec.bodies()[0])


async def test_route_info_and_health_without_network() -> None:
    gw, rec, _ = build_gateway(by_host(), env={"GEM_KEY": "k"}, grants=Grants())
    info = {r.task: r for r in await gw.route_info(CLOUD)}
    assert info[TaskClass.ROUTINE_CHAT].active_model == "g-flash"
    assert info[TaskClass.ROUTINE_CHAT].locality is Locality.EXTERNAL
    strict = {r.task: r for r in await gw.route_info(STRICT)}
    assert strict[TaskClass.ROUTINE_CHAT].active_model is None
    assert strict[TaskClass.EMBEDDING].active_model == LOCAL_HASH_MODEL_ID
    health = gw.health()
    assert health["gem"]["enabled"] and not health["oai"]["enabled"]
    assert health["gem"]["models"]["g-flash"]["breaker"] == "closed"
    assert rec.requests == []
    assert ENV  # shared env untouched
