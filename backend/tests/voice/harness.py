"""Test plugin for the voice package: real routes and service, injectable env and HTTP transport."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import httpx

from app.providers.config import ConfigStore
from app.providers.plugin import config_path
from app.voice.plugin import install

ENV: dict[str, str] = {}
SEEN: list[httpx.Request] = []
HANDLER: dict[str, Callable[[httpx.Request], httpx.Response]] = {}


def _transport(request: httpx.Request) -> httpx.Response:
    SEEN.append(request)
    handler = HANDLER.get("fn")
    if handler is None:
        raise AssertionError(f"unexpected external call to {request.url}")
    return handler(request)


def register(reg: Any) -> None:
    models = ConfigStore(config_path(reg.service("settings")), env=ENV)
    install(
        reg,
        models=models,
        env=ENV,
        http=lambda: httpx.AsyncClient(transport=httpx.MockTransport(_transport)),
    )
