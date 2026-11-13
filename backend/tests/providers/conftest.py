"""Test-only provider config (sample model names are fine under tests/) and helpers."""

from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any

import httpx
import pytest

from app.core.types import DataClass
from app.providers.config import ModelsConfig, StaticConfig, parse_config
from app.providers.gateway import ModelGateway
from app.providers.resilience import RetryPolicy
from app.providers.usage import MemoryUsageSink

ENV = {"GEM_KEY": "test-gem-key", "OAI_KEY": "test-oai-key", "LOCAL_URL": "http://local.test/v1"}


def raw_config() -> dict[str, Any]:
    return {
        "providers": [
            {
                "id": "gem",
                "kind": "gemini",
                "base_url": "https://gem.test/v1beta",
                "api_key_env": "GEM_KEY",
                "locality": "external",
                "allowed_data_classes": ["public", "personal", "sensitive", "financial", "health"],
            },
            {
                "id": "oai",
                "kind": "openai_compatible",
                "base_url": "https://oai.test/v1",
                "api_key_env": "OAI_KEY",
                "locality": "external",
                "allowed_data_classes": ["public", "personal"],
            },
            {
                "id": "local",
                "kind": "openai_compatible",
                "base_url_env": "LOCAL_URL",
                "keyless": True,
                "locality": "local",
                "allowed_data_classes": ["public", "personal", "sensitive", "financial", "health"],
            },
        ],
        "models": [
            {
                "id": "g-flash",
                "provider": "gem",
                "model_name": "gem-flash-x",
                "context_window": 100000,
                "price_in": "0.75",
                "price_out": "3.75",
                "capabilities": ["chat", "tools", "structured", "stream"],
            },
            {
                "id": "o-mini",
                "provider": "oai",
                "model_name": "oai-mini-x",
                "context_window": 100000,
                "price_in": "0.10",
                "price_out": "0.50",
                "capabilities": ["chat", "tools", "structured", "stream"],
            },
            {
                "id": "l-small",
                "provider": "local",
                "model_name": "local-x",
                "context_window": 100000,
                "capabilities": ["chat", "stream"],
            },
            {
                "id": "g-embed",
                "provider": "gem",
                "model_name": "gem-embed-x",
                "context_window": 2048,
                "price_in": "0.20",
                "capabilities": ["embed"],
            },
        ],
        "routes": {
            "routine_chat": ["g-flash", "o-mini", "l-small"],
            "complex_reasoning": ["g-flash", "o-mini"],
            "embedding": ["g-embed"],
        },
    }


def make_config(**overrides: Any) -> ModelsConfig:
    raw = raw_config()
    raw.update(overrides)
    return parse_config(raw)


class Grants:
    def __init__(self, granted: frozenset[DataClass] = frozenset(), strict_public: bool = False) -> None:
        self.granted = granted
        self.strict_public = strict_public

    async def egress_overrides(self) -> tuple[bool, frozenset[DataClass]]:
        return self.strict_public, self.granted


class Recorder:
    """httpx MockTransport handler that records requests and answers from a per-host script."""

    def __init__(self, handler: Callable[[httpx.Request], httpx.Response]) -> None:
        self.handler = handler
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return self.handler(request)

    def bodies(self) -> list[dict[str, Any]]:
        return [json.loads(r.content) for r in self.requests]

    def hosts(self) -> list[str]:
        return [r.url.host for r in self.requests]


def gemini_text(text: str, tin: int = 10, tout: int = 5) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "candidates": [{"content": {"role": "model", "parts": [{"text": text}]}, "finishReason": "STOP"}],
            "usageMetadata": {"promptTokenCount": tin, "candidatesTokenCount": tout},
        },
    )


def openai_text(text: str, tin: int = 7, tout: int = 3) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "choices": [
                {"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}
            ],
            "usage": {"prompt_tokens": tin, "completion_tokens": tout},
        },
    )


class Sleeps:
    def __init__(self) -> None:
        self.calls: list[float] = []

    async def __call__(self, seconds: float) -> None:
        self.calls.append(seconds)


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def sleeps() -> Sleeps:
    return Sleeps()


def build_gateway(
    handler: Callable[[httpx.Request], httpx.Response],
    *,
    env: dict[str, str] | None = None,
    grants: Grants | None = None,
    clock: Clock | None = None,
    sleeps: Sleeps | None = None,
    config: ModelsConfig | None = None,
    retry: RetryPolicy | None = None,
) -> tuple[ModelGateway, Recorder, MemoryUsageSink]:
    rec = Recorder(handler)
    usage = MemoryUsageSink()
    gw = ModelGateway(
        StaticConfig(config or make_config(), ENV if env is None else env),
        http=httpx.AsyncClient(transport=httpx.MockTransport(rec)),
        privacy_state=grants,
        usage=usage,
        retry=retry or RetryPolicy(max_attempts=2),
        sleep=sleeps or Sleeps(),
        rand=lambda: 0.5,
        clock=clock or Clock(),
    )
    return gw, rec, usage
