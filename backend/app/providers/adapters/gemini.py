"""Gemini native REST adapter (v1beta generateContent / streamGenerateContent / batchEmbedContents).

Shapes checked against the official API reference on 2026-11-13 (aistudio.google.com/api-reference):
Content{role user|model, parts}, Part{text, functionCall{name,args,id}, functionResponse{name,response,id},
thought, thoughtSignature}, FunctionDeclaration{name, description, parametersJsonSchema},
GenerationConfig{temperature, maxOutputTokens, responseMimeType, responseJsonSchema}, finishReason values,
usageMetadata{promptTokenCount, candidatesTokenCount, thoughtsTokenCount}.
Not confirmed on a fetched page: the `alt=sse` framing and the batchEmbedContents response body
(`embeddings[].values`); both follow the long-standing public format.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any

import httpx

from app.providers.adapters.base import (
    AdapterRequest,
    post_json,
    stream_sse,
    tool_names_by_call_id,
    tool_result_object,
)
from app.providers.config import ModelEntry, ResolvedProvider
from app.providers.types import ChatChunk, ChatMessage, ChatResponse, ProviderError, ToolCall, Usage

_FINISH = {"STOP": "stop", "MAX_TOKENS": "length"}
_FILTERED = {"SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "LANGUAGE"}


def _headers(provider: ResolvedProvider) -> dict[str, str]:
    return {"x-goog-api-key": provider.api_key or "", "content-type": "application/json"}


def _contents(messages: tuple[ChatMessage, ...]) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    system = [m.content for m in messages if m.role == "system" and m.content]
    names = tool_names_by_call_id(messages)
    contents: list[dict[str, Any]] = []
    for m in messages:
        if m.role == "system":
            continue
        parts: list[dict[str, Any]] = []
        if m.role == "tool":
            role = "user"
            name = m.name or names.get(m.tool_call_id or "", "tool")
            fr: dict[str, Any] = {"name": name, "response": tool_result_object(m.content)}
            if m.tool_call_id:
                fr["id"] = m.tool_call_id
            parts.append({"functionResponse": fr})
        else:
            role = "model" if m.role == "assistant" else "user"
            if m.content:
                parts.append({"text": m.content})
            for tc in m.tool_calls:
                part: dict[str, Any] = {"functionCall": {"name": tc.name, "args": tc.arguments, "id": tc.id}}
                if tc.signature:
                    part["thoughtSignature"] = tc.signature
                parts.append(part)
        if not parts:
            continue
        if contents and contents[-1]["role"] == role:
            contents[-1]["parts"].extend(parts)  # Gemini wants alternating turns
        else:
            contents.append({"role": role, "parts": parts})
    sys_instr = {"parts": [{"text": "\n\n".join(system)}]} if system else None
    return sys_instr, contents


def build_body(req: AdapterRequest) -> dict[str, Any]:
    sys_instr, contents = _contents(req.messages)
    body: dict[str, Any] = {"contents": contents}
    if sys_instr:
        body["systemInstruction"] = sys_instr
    if req.tools:
        body["tools"] = [
            {
                "functionDeclarations": [
                    {"name": t.name, "description": t.description, "parametersJsonSchema": t.parameters}
                    for t in req.tools
                ]
            }
        ]
    gen: dict[str, Any] = {"maxOutputTokens": req.max_output_tokens}
    if req.temperature is not None:
        gen["temperature"] = req.temperature
    if req.response_schema is not None:
        gen["responseMimeType"] = "application/json"
        gen["responseJsonSchema"] = req.response_schema
    body["generationConfig"] = gen
    return body


def _usage(data: dict[str, Any]) -> Usage | None:
    meta = data.get("usageMetadata")
    if not isinstance(meta, dict):
        return None
    out = int(meta.get("candidatesTokenCount", 0)) + int(meta.get("thoughtsTokenCount", 0))
    return Usage(input_tokens=int(meta.get("promptTokenCount", 0)), output_tokens=out)


def _parse_candidate(data: dict[str, Any], call_offset: int = 0) -> tuple[str, list[ToolCall], str | None]:
    feedback = data.get("promptFeedback")
    if isinstance(feedback, dict) and feedback.get("blockReason"):
        raise ProviderError("blocked", f"prompt blocked: {feedback['blockReason']}")
    candidates = data.get("candidates") or []
    if not candidates:
        return "", [], None
    cand = candidates[0]
    text: list[str] = []
    calls: list[ToolCall] = []
    for part in (cand.get("content") or {}).get("parts") or []:
        if part.get("thought"):
            continue
        if "text" in part:
            text.append(str(part["text"]))
        fc = part.get("functionCall")
        if isinstance(fc, dict):
            calls.append(
                ToolCall(
                    id=str(fc.get("id") or f"call_{call_offset + len(calls)}"),
                    name=str(fc.get("name", "")),
                    arguments=dict(fc.get("args") or {}),
                    signature=part.get("thoughtSignature"),
                )
            )
    raw = cand.get("finishReason")
    finish: str | None = None
    if raw:
        finish = "content_filter" if raw in _FILTERED else _FINISH.get(raw, "other")
    return "".join(text), calls, finish


class GeminiAdapter:
    def __init__(self, http: httpx.AsyncClient) -> None:
        self._http = http

    @staticmethod
    def _url(req: AdapterRequest, method: str) -> str:
        return f"{req.provider.base_url}/models/{req.model.model_name}:{method}"

    async def chat(self, req: AdapterRequest) -> ChatResponse:
        data = await post_json(
            self._http,
            self._url(req, "generateContent"),
            headers=_headers(req.provider),
            body=build_body(req),
            timeout_s=req.timeout_s,
        )
        text, calls, finish = _parse_candidate(data)
        if finish == "content_filter" and not text and not calls:
            raise ProviderError("blocked", "response withheld by provider safety filter")
        if calls:
            finish = "tool_calls"
        return ChatResponse(
            text=text,
            tool_calls=tuple(calls),
            usage=_usage(data) or Usage(),
            provider=req.provider.entry.id,
            model=req.model.id,
            finish_reason=finish or "stop",
        )

    async def stream(self, req: AdapterRequest) -> AsyncIterator[ChatChunk]:
        url = self._url(req, "streamGenerateContent") + "?alt=sse"
        usage: Usage | None = None
        finish: str | None = None
        n_calls = 0
        async for event in stream_sse(
            self._http, url, headers=_headers(req.provider), body=build_body(req), timeout_s=req.timeout_s
        ):
            text, calls, fin = _parse_candidate(event, n_calls)
            n_calls += len(calls)
            usage = _usage(event) or usage
            finish = fin or finish
            if text or calls:
                yield ChatChunk(
                    delta=text, tool_calls=tuple(calls), provider=req.provider.entry.id, model=req.model.id
                )
        yield ChatChunk(
            done=True,
            finish_reason="tool_calls" if n_calls else (finish or "stop"),
            usage=usage or Usage(),
            provider=req.provider.entry.id,
            model=req.model.id,
        )

    async def embed(
        self, provider: ResolvedProvider, model: ModelEntry, texts: list[str], timeout_s: float
    ) -> tuple[list[list[float]], int]:
        body = {
            "requests": [
                {"model": f"models/{model.model_name}", "content": {"parts": [{"text": t}]}} for t in texts
            ]
        }
        data = await post_json(
            self._http,
            f"{provider.base_url}/models/{model.model_name}:batchEmbedContents",
            headers=_headers(provider),
            body=body,
            timeout_s=timeout_s,
        )
        items = data.get("embeddings") or []
        if len(items) != len(texts):
            raise ProviderError("unavailable", "embedding count mismatch")
        vectors = [[float(v) for v in item.get("values") or []] for item in items]
        tokens = int((data.get("usageMetadata") or {}).get("promptTokenCount", 0))
        return vectors, tokens
