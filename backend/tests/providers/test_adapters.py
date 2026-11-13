from __future__ import annotations

import json
from typing import Any

import httpx
import pytest

from app.providers.adapters import AdapterRequest, GeminiAdapter, OpenAICompatAdapter
from app.providers.adapters.base import parse_retry_after
from app.providers.config import StaticConfig
from app.providers.types import ChatMessage, ProviderError, ToolCall, ToolDef
from tests.providers.conftest import ENV, Recorder, make_config

TOOL = ToolDef(
    name="weather",
    description="Weather for a city",
    parameters={"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]},
)
SCHEMA = {"type": "object", "properties": {"intent": {"type": "string"}}, "required": ["intent"]}
CALL = ToolCall(id="call_7", name="weather", arguments={"city": "Pune"}, signature="sig-abc")
CONVO = (
    ChatMessage(role="system", content="You are ZORO."),
    ChatMessage(role="user", content="Weather in Pune?"),
    ChatMessage(role="assistant", content="", tool_calls=(CALL,)),
    ChatMessage(role="tool", content='{"temp_c": 31}', tool_call_id="call_7"),
)


def _areq(model_id: str, **kw: Any) -> AdapterRequest:
    src = StaticConfig(make_config(), ENV)
    model = src.current().model(model_id)
    return AdapterRequest(provider=src.resolve(model.provider), model=model, messages=CONVO, **kw)


def _client(handler: Recorder) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _sse(events: list[dict[str, Any] | str]) -> httpx.Response:
    body = "".join(f"data: {e if isinstance(e, str) else json.dumps(e)}\n\n" for e in events)
    return httpx.Response(200, content=body.encode(), headers={"content-type": "text/event-stream"})


# ---- Gemini -------------------------------------------------------------------------------------


async def test_gemini_request_and_tool_call_response() -> None:
    rec = Recorder(
        lambda r: httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {
                            "role": "model",
                            "parts": [
                                {"text": "thinking", "thought": True},
                                {
                                    "functionCall": {"name": "weather", "args": {"city": "Mumbai"}},
                                    "thoughtSignature": "s2",
                                },
                            ],
                        },
                        "finishReason": "STOP",
                    }
                ],
                "usageMetadata": {"promptTokenCount": 40, "candidatesTokenCount": 6, "thoughtsTokenCount": 4},
            },
        )
    )
    resp = await GeminiAdapter(_client(rec)).chat(_areq("g-flash", tools=(TOOL,), temperature=0.2))
    req = rec.requests[0]
    assert str(req.url) == "https://gem.test/v1beta/models/gem-flash-x:generateContent"
    assert req.headers["x-goog-api-key"] == "test-gem-key"
    body = json.loads(req.content)
    assert body["systemInstruction"] == {"parts": [{"text": "You are ZORO."}]}
    assert [c["role"] for c in body["contents"]] == ["user", "model", "user"]
    model_part = body["contents"][1]["parts"][0]
    assert model_part == {
        "functionCall": {"name": "weather", "args": {"city": "Pune"}, "id": "call_7"},
        "thoughtSignature": "sig-abc",
    }
    fr = body["contents"][2]["parts"][0]["functionResponse"]
    assert fr == {"name": "weather", "response": {"temp_c": 31}, "id": "call_7"}
    decl = body["tools"][0]["functionDeclarations"][0]
    assert decl["name"] == "weather" and decl["parametersJsonSchema"] == TOOL.parameters
    assert body["generationConfig"] == {"maxOutputTokens": 1024, "temperature": 0.2}

    assert resp.text == ""  # thought parts are not answer text
    assert resp.finish_reason == "tool_calls"
    assert resp.tool_calls[0].name == "weather"
    assert resp.tool_calls[0].arguments == {"city": "Mumbai"}
    assert resp.tool_calls[0].signature == "s2"
    assert (resp.usage.input_tokens, resp.usage.output_tokens) == (40, 10)


async def test_gemini_structured_output_request() -> None:
    rec = Recorder(
        lambda r: httpx.Response(200, json={"candidates": [{"content": {"parts": [{"text": "{}"}]}}]})
    )
    await GeminiAdapter(_client(rec)).chat(_areq("g-flash", response_schema=SCHEMA))
    gen = json.loads(rec.requests[0].content)["generationConfig"]
    assert gen["responseMimeType"] == "application/json"
    assert gen["responseJsonSchema"] == SCHEMA


async def test_gemini_prompt_blocked() -> None:
    rec = Recorder(lambda r: httpx.Response(200, json={"promptFeedback": {"blockReason": "SAFETY"}}))
    with pytest.raises(ProviderError) as ei:
        await GeminiAdapter(_client(rec)).chat(_areq("g-flash"))
    assert ei.value.kind == "blocked"


async def test_gemini_stream_sse() -> None:
    rec = Recorder(
        lambda r: _sse(
            [
                {"candidates": [{"content": {"parts": [{"text": "Namaste "}]}}]},
                {
                    "candidates": [{"content": {"parts": [{"text": "Pune"}]}, "finishReason": "STOP"}],
                    "usageMetadata": {"promptTokenCount": 9, "candidatesTokenCount": 2},
                },
            ]
        )
    )
    chunks = [c async for c in GeminiAdapter(_client(rec)).stream(_areq("g-flash"))]
    assert rec.requests[0].url.params["alt"] == "sse"
    assert rec.requests[0].url.path.endswith(":streamGenerateContent")
    assert "".join(c.delta for c in chunks) == "Namaste Pune"
    assert chunks[-1].done and chunks[-1].finish_reason == "stop"
    assert chunks[-1].usage is not None and chunks[-1].usage.output_tokens == 2


async def test_gemini_embeddings() -> None:
    rec = Recorder(
        lambda r: httpx.Response(200, json={"embeddings": [{"values": [0.1, 0.2]}, {"values": [0.3, 0.4]}]})
    )
    src = StaticConfig(make_config(), ENV)
    model = src.current().model("g-embed")
    vecs, _ = await GeminiAdapter(_client(rec)).embed(src.resolve("gem"), model, ["a", "b"], 5)
    assert vecs == [[0.1, 0.2], [0.3, 0.4]]
    body = json.loads(rec.requests[0].content)
    assert rec.requests[0].url.path.endswith("/models/gem-embed-x:batchEmbedContents")
    assert body["requests"][1] == {"model": "models/gem-embed-x", "content": {"parts": [{"text": "b"}]}}


# ---- OpenAI-compatible --------------------------------------------------------------------------


async def test_openai_request_and_tool_call_response() -> None:
    rec = Recorder(
        lambda r: httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "role": "assistant",
                            "content": None,
                            "tool_calls": [
                                {
                                    "id": "t1",
                                    "type": "function",
                                    "function": {"name": "weather", "arguments": '{"city":"Delhi"}'},
                                }
                            ],
                        },
                        "finish_reason": "tool_calls",
                    }
                ],
                "usage": {"prompt_tokens": 21, "completion_tokens": 8},
            },
        )
    )
    resp = await OpenAICompatAdapter(_client(rec)).chat(
        _areq("o-mini", tools=(TOOL,), response_schema=SCHEMA)
    )
    req = rec.requests[0]
    assert str(req.url) == "https://oai.test/v1/chat/completions"
    assert req.headers["authorization"] == "Bearer test-oai-key"
    body = json.loads(req.content)
    assert body["model"] == "oai-mini-x" and body["max_tokens"] == 1024
    assert body["messages"][2]["tool_calls"][0] == {
        "id": "call_7",
        "type": "function",
        "function": {"name": "weather", "arguments": '{"city": "Pune"}'},
    }
    assert body["messages"][3] == {"role": "tool", "tool_call_id": "call_7", "content": '{"temp_c": 31}'}
    assert body["tools"][0] == {
        "type": "function",
        "function": {"name": "weather", "description": TOOL.description, "parameters": TOOL.parameters},
    }
    assert body["response_format"] == {
        "type": "json_schema",
        "json_schema": {"name": "response", "schema": SCHEMA},
    }
    assert resp.tool_calls == (ToolCall(id="t1", name="weather", arguments={"city": "Delhi"}),)
    assert resp.finish_reason == "tool_calls"
    assert (resp.usage.input_tokens, resp.usage.output_tokens) == (21, 8)


async def test_openai_keyless_local_sends_no_auth() -> None:
    rec = Recorder(
        lambda r: httpx.Response(
            200, json={"choices": [{"message": {"content": "hi"}, "finish_reason": "stop"}]}
        )
    )
    resp = await OpenAICompatAdapter(_client(rec)).chat(_areq("l-small"))
    assert "authorization" not in rec.requests[0].headers
    assert str(rec.requests[0].url) == "http://local.test/v1/chat/completions"
    assert resp.text == "hi"


async def test_openai_malformed_tool_arguments() -> None:
    rec = Recorder(
        lambda r: httpx.Response(
            200,
            json={
                "choices": [
                    {"message": {"tool_calls": [{"id": "x", "function": {"name": "w", "arguments": "{bad"}}]}}
                ]
            },
        )
    )
    with pytest.raises(ProviderError) as ei:
        await OpenAICompatAdapter(_client(rec)).chat(_areq("o-mini"))
    assert ei.value.kind == "bad_request"


async def test_openai_stream_text_and_tool_call_fragments() -> None:
    rec = Recorder(
        lambda r: _sse(
            [
                {"choices": [{"delta": {"content": "Check"}}]},
                {"choices": [{"delta": {"content": "ing"}}]},
                {
                    "choices": [
                        {
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "t9",
                                        "function": {"name": "weather", "arguments": '{"ci'},
                                    }
                                ]
                            }
                        }
                    ]
                },
                {
                    "choices": [
                        {
                            "delta": {"tool_calls": [{"index": 0, "function": {"arguments": 'ty":"Goa"}'}}]},
                            "finish_reason": "tool_calls",
                        }
                    ]
                },
                {"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 4}},
                "[DONE]",
            ]
        )
    )
    chunks = [c async for c in OpenAICompatAdapter(_client(rec)).stream(_areq("o-mini"))]
    body = json.loads(rec.requests[0].content)
    assert body["stream"] is True and body["stream_options"] == {"include_usage": True}
    assert "".join(c.delta for c in chunks) == "Checking"
    calls = [tc for c in chunks for tc in c.tool_calls]
    assert calls == [ToolCall(id="t9", name="weather", arguments={"city": "Goa"})]
    assert chunks[-1].done and chunks[-1].finish_reason == "tool_calls"
    assert chunks[-1].usage is not None and chunks[-1].usage.input_tokens == 5


async def test_openai_embeddings_sorted_by_index() -> None:
    rec = Recorder(
        lambda r: httpx.Response(
            200, json={"data": [{"index": 1, "embedding": [2.0]}, {"index": 0, "embedding": [1.0]}]}
        )
    )
    src = StaticConfig(make_config(), ENV)
    vecs, _ = await OpenAICompatAdapter(_client(rec)).embed(
        src.resolve("oai"), src.current().model("o-mini"), ["a", "b"], 5
    )
    assert vecs == [[1.0], [2.0]]
    assert rec.requests[0].url.path == "/v1/embeddings"


# ---- error mapping ------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("status", "kind"),
    [
        (429, "rate_limited"),
        (401, "auth"),
        (403, "auth"),
        (500, "unavailable"),
        (503, "unavailable"),
        (504, "timeout"),
        (400, "bad_request"),
    ],
)
async def test_status_mapping(status: int, kind: str) -> None:
    rec = Recorder(
        lambda r: httpx.Response(status, json={"error": {"message": "nope"}}, headers={"retry-after": "2"})
    )
    with pytest.raises(ProviderError) as ei:
        await OpenAICompatAdapter(_client(rec)).chat(_areq("o-mini"))
    assert ei.value.kind == kind
    if kind == "rate_limited":
        assert ei.value.retry_after_s == 2.0


async def test_transport_timeout_maps_to_timeout() -> None:
    def boom(r: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow", request=r)

    with pytest.raises(ProviderError) as ei:
        await GeminiAdapter(_client(Recorder(boom))).chat(_areq("g-flash"))
    assert ei.value.kind == "timeout"


def test_retry_after_http_date() -> None:
    from datetime import UTC, datetime

    now = datetime(2026, 11, 13, 10, 0, 0, tzinfo=UTC)
    assert parse_retry_after("Fri, 13 Nov 2026 10:00:05 GMT", now) == 5.0
    assert parse_retry_after("garbage") is None
