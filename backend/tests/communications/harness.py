"""Test plugin for the communications package: real routes, tools, OAuth and Gmail over a mock transport."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import httpx

from app.communications.plugin import install

ENV: dict[str, str] = {}
SEEN: list[httpx.Request] = []
ROUTES: dict[tuple[str, str], Callable[[httpx.Request], httpx.Response]] = {}


def _transport(request: httpx.Request) -> httpx.Response:
    SEEN.append(request)
    handler = ROUTES.get((request.method, request.url.host + request.url.path))
    if handler is None:
        raise AssertionError(f"unexpected external call {request.method} {request.url}")
    return handler(request)


def register(reg: Any) -> None:
    install(reg, env=ENV, http=lambda: httpx.AsyncClient(transport=httpx.MockTransport(_transport)))
