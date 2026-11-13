"""OpenAI-compatible Chat Completions adapter (OpenAI, xAI, DeepSeek, Qwen, Kimi, Groq, Together, Ollama).

POST {base}/chat/completions with Bearer auth (omitted for keyless local servers), function tools,
`response_format: {type: json_schema}` for structured output, SSE streaming ending in `data: [DONE]`,
and POST {base}/embeddings.
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from typing import Any

import httpx

from app.providers.adapters.base import AdapterRequest, post_json, stream_sse
from app.providers.config import ModelEntry, ResolvedProvider
from app.providers.types import ChatChunk, ChatMessage, ChatResponse, ProviderError, ToolCall, Usage


def _headers(provider: ResolvedProvider) -> dict[str, str]:
    headers = {"content-type": "application/json"}
    if provider.api_key:
        headers["authorization"] = f"Bearer {provider.api_key}"
    return headers


def _message(m: ChatMessage) -> dict[str, Any]:
    if m.role == "tool":
        return {"role": "tool", "tool_call_id": m.tool_call_id or "", "content": m.content}
    out: dict[str, Any] = {"role": m.role, "content": m.content}
    if m.role == "assistant" and m.tool_calls:
        out["content"] = m.content or None
        out["tool_calls"] = [
            {
                "id": tc.id,
                "type": "function",
                "function": {"name": tc.name, "arguments": json.dumps(tc.arguments, ensure_ascii=False)},
            }
            for tc in m.tool_calls
        ]
    return out


def build_body(req: AdapterRequest, *, stream: bool = False) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": req.model.model_name,
        "messages": [_message(m) for m in req.messages],
        req.provider.entry.max_tokens_field: req.max_output_tokens,
    }
    if req.temperature is not None:
        body["temperature"] = req.temperature
    if req.tools:
        body["tools"] = [
            {
                "type": "function",
                "function": {"name": t.name, "description": t.description, "parameters": t.parameters},
            }
            for t in req.tools
        ]
    if req.response_schema is not None:
        body["response_format"] = {
            "type": "json_schema",
            "json_schema": {"name": "response", "schema": req.response_schema},
        }
    if stream:
        body["stream"] = True
        if req.provider.entry.stream_usage:
            body["stream_options"] = {"include_usage": True}
    return body


def _arguments(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        raise ProviderError("bad_request", "model returned malformed tool-call arguments") from None
    if not isinstance(value, dict):
        raise ProviderError("bad_request", "tool-call arguments are not an object")
    return value


def _usage(data: dict[str, Any]) -> Usage | None:
    u = data.get("usage")
    if not isinstance(u, dict):
        return None
    return Usage(
        input_tokens=int(u.get("prompt_tokens") or 0), output_tokens=int(u.get("completion_tokens") or 0)
    )


class OpenAICompatAdapter:
    def __init__(self, http: httpx.AsyncClient) -> None:
        self._http = http

    async def chat(self, req: AdapterRequest) -> ChatResponse:
        data = await post_json(
            self._http,
            f"{req.provider.base_url}/chat/completions",
            headers=_headers(req.provider),
            body=build_body(req),
            timeout_s=req.timeout_s,
        )
        choices = data.get("choices") or []
        if not choices:
            raise ProviderError("unavailable", "response has no choices")
        msg = choices[0].get("message") or {}
        calls = tuple(
            ToolCall(
                id=str(tc.get("id") or f"call_{i}"),
                name=str(fn.get("name", "")),
                arguments=_arguments(fn.get("arguments")),
            )
            for i, tc in enumerate(msg.get("tool_calls") or [])
            for fn in [tc.get("function") or {}]
        )
        finish = str(choices[0].get("finish_reason") or ("tool_calls" if calls else "stop"))
        if finish == "content_filter" and not msg.get("content") and not calls:
            raise ProviderError("blocked", "response withheld by provider content filter")
        return ChatResponse(
            text=str(msg.get("content") or ""),
            tool_calls=calls,
            usage=_usage(data) or Usage(),
            provider=req.provider.entry.id,
            model=req.model.id,
            finish_reason=finish,
        )

    async def stream(self, req: AdapterRequest) -> AsyncIterator[ChatChunk]:
        pending: dict[int, dict[str, str]] = {}
        usage: Usage | None = None
        finish: str | None = None
        async for event in stream_sse(
            self._http,
            f"{req.provider.base_url}/chat/completions",
            headers=_headers(req.provider),
            body=build_body(req, stream=True),
            timeout_s=req.timeout_s,
        ):
            usage = _usage(event) or usage
            for choice in event.get("choices") or []:
                delta = choice.get("delta") or {}
                for tc in delta.get("tool_calls") or []:
                    slot = pending.setdefault(int(tc.get("index", 0)), {"id": "", "name": "", "args": ""})
                    fn = tc.get("function") or {}
                    slot["id"] = tc.get("id") or slot["id"]
                    slot["name"] += fn.get("name") or ""
                    slot["args"] += fn.get("arguments") or ""
                finish = choice.get("finish_reason") or finish
                if delta.get("content"):
                    yield ChatChunk(
                        delta=str(delta["content"]), provider=req.provider.entry.id, model=req.model.id
                    )
        calls = tuple(
            ToolCall(id=s["id"] or f"call_{i}", name=s["name"], arguments=_arguments(s["args"]))
            for i, s in sorted(pending.items())
        )
        if calls:
            yield ChatChunk(tool_calls=calls, provider=req.provider.entry.id, model=req.model.id)
        yield ChatChunk(
            done=True,
            finish_reason=finish or ("tool_calls" if calls else "stop"),
            usage=usage or Usage(),
            provider=req.provider.entry.id,
            model=req.model.id,
        )

    async def embed(
        self, provider: ResolvedProvider, model: ModelEntry, texts: list[str], timeout_s: float
    ) -> tuple[list[list[float]], int]:
        data = await post_json(
            self._http,
            f"{provider.base_url}/embeddings",
            headers=_headers(provider),
            body={"model": model.model_name, "input": texts},
            timeout_s=timeout_s,
        )
        items = sorted(data.get("data") or [], key=lambda d: int(d.get("index", 0)))
        if len(items) != len(texts):
            raise ProviderError("unavailable", "embedding count mismatch")
        usage = _usage(data)
        return [
            [float(v) for v in it.get("embedding") or []] for it in items
        ], usage.input_tokens if usage else 0
