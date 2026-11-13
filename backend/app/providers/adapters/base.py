"""Shared adapter plumbing: the request an adapter receives, HTTP error mapping and SSE parsing."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from typing import Any, Protocol

import httpx

from app.providers.config import ModelEntry, ResolvedProvider
from app.providers.types import ChatChunk, ChatMessage, ChatResponse, ProviderError, ToolDef


@dataclass(frozen=True)
class AdapterRequest:
    """What the gateway hands an adapter after egress, redaction and trimming."""

    provider: ResolvedProvider
    model: ModelEntry
    messages: tuple[ChatMessage, ...]
    tools: tuple[ToolDef, ...] = ()
    response_schema: dict[str, Any] | None = None
    max_output_tokens: int = 1024
    temperature: float | None = None
    timeout_s: float = 30.0


class ProviderAdapter(Protocol):
    async def chat(self, req: AdapterRequest) -> ChatResponse: ...

    def stream(self, req: AdapterRequest) -> AsyncIterator[ChatChunk]: ...

    async def embed(
        self, provider: ResolvedProvider, model: ModelEntry, texts: list[str], timeout_s: float
    ) -> tuple[list[list[float]], int]:
        """Return (vectors, input_tokens)."""
        ...


def parse_retry_after(value: str | None, now: datetime | None = None) -> float | None:
    if not value:
        return None
    value = value.strip()
    try:
        return max(0.0, float(value))
    except ValueError:
        pass
    try:
        when = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=UTC)
    return max(0.0, (when - (now or datetime.now(UTC))).total_seconds())


def _error_message(body: bytes) -> str:
    """A short provider error message. Never the full body: it may echo prompt content."""
    try:
        data = json.loads(body)
    except ValueError:
        return ""
    err = data.get("error") if isinstance(data, dict) else None
    msg = err.get("message") if isinstance(err, dict) else err if isinstance(err, str) else None
    return str(msg)[:200] if msg else ""


def error_for_status(resp: httpx.Response, body: bytes) -> ProviderError:
    code = resp.status_code
    msg = f"http {code} {_error_message(body)}".strip()
    if code == 429:
        return ProviderError(
            "rate_limited", msg, retry_after_s=parse_retry_after(resp.headers.get("retry-after"))
        )
    if code in (401, 403):
        return ProviderError("auth", f"http {code}")
    if code in (408, 504):
        return ProviderError("timeout", msg)
    if code >= 500:
        return ProviderError("unavailable", msg)
    return ProviderError("bad_request", msg)


def map_transport_error(exc: httpx.HTTPError) -> ProviderError:
    if isinstance(exc, httpx.TimeoutException):
        return ProviderError("timeout", type(exc).__name__)
    return ProviderError("unavailable", type(exc).__name__)


async def post_json(
    http: httpx.AsyncClient, url: str, *, headers: dict[str, str], body: dict[str, Any], timeout_s: float
) -> dict[str, Any]:
    try:
        resp = await http.post(url, headers=headers, json=body, timeout=timeout_s)
    except httpx.HTTPError as exc:
        raise map_transport_error(exc) from None
    if resp.status_code >= 400:
        raise error_for_status(resp, resp.content)
    try:
        data = resp.json()
    except ValueError:
        raise ProviderError("unavailable", "response is not JSON") from None
    if not isinstance(data, dict):
        raise ProviderError("unavailable", "response is not a JSON object")
    return data


async def stream_sse(
    http: httpx.AsyncClient, url: str, *, headers: dict[str, str], body: dict[str, Any], timeout_s: float
) -> AsyncIterator[dict[str, Any]]:
    """POST and yield each `data:` event as JSON. Stops at `[DONE]` (OpenAI) or end of stream."""
    try:
        async with http.stream("POST", url, headers=headers, json=body, timeout=timeout_s) as resp:
            if resp.status_code >= 400:
                raise error_for_status(resp, await resp.aread())
            buf: list[str] = []
            async for line in resp.aiter_lines():
                if line.startswith("data:"):
                    buf.append(line[5:].lstrip())
                    continue
                if line.strip() == "" and buf:
                    payload = "\n".join(buf)
                    buf = []
                    if payload == "[DONE]":
                        return
                    yield _event(payload)
            if buf and "\n".join(buf) != "[DONE]":
                yield _event("\n".join(buf))
    except httpx.HTTPError as exc:
        raise map_transport_error(exc) from None


def _event(payload: str) -> dict[str, Any]:
    try:
        data = json.loads(payload)
    except ValueError:
        raise ProviderError("unavailable", "malformed stream event") from None
    if not isinstance(data, dict):
        raise ProviderError("unavailable", "malformed stream event")
    return data


def tool_names_by_call_id(messages: tuple[ChatMessage, ...]) -> dict[str, str]:
    return {tc.id: tc.name for m in messages for tc in m.tool_calls}


def tool_result_object(content: str) -> dict[str, Any]:
    try:
        value = json.loads(content)
    except ValueError:
        return {"result": content}
    return value if isinstance(value, dict) else {"result": value}
