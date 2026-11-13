"""The route table: device sessions on every /v1 route, no photo uploads, unauthenticated probes."""

from __future__ import annotations

import re
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any

import httpx
import pytest
from fastapi import APIRouter, FastAPI, UploadFile
from starlette.routing import Mount
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

#: Public by design.
PUBLIC_PREFIXES = ("/healthz", "/v1/auth/")
#: Browser redirects from an OAuth provider: they carry no device token, and only complete a flow a
#: paired device started (the provider's `state` is checked). Each is probed below.
OAUTH_CALLBACKS = {
    "/v1/music/callback",
    "/v1/communications/gmail/callback",
    "/v1/shopping/providers/{provider_id}/oauth/callback",
}
#: Authenticate inside the handler (WebSocket token, MCP bearer token); probed below.
SELF_AUTHENTICATING = {"/v1/devices/channel"}


@dataclass(frozen=True)
class RouteInfo:
    path: str
    methods: frozenset[str]
    dependencies: frozenset[str]
    endpoint: Any
    kind: str  # "http" | "ws" | "mount"


def _dependency_names(dependant: Any, out: set[str]) -> set[str]:
    for sub in getattr(dependant, "dependencies", []) or []:
        out.add(getattr(sub.call, "__name__", repr(sub.call)))
        _dependency_names(sub, out)
    return out


def _walk(routes: list[Any]) -> Iterator[Any]:
    for route in routes:
        candidates = getattr(route, "effective_candidates", None)
        if callable(candidates):  # FastAPI >= 0.16x keeps included routers lazily
            yield from _walk(candidates())
        else:
            yield route


def route_table(app: FastAPI) -> list[RouteInfo]:
    table: list[RouteInfo] = []
    for entry in _walk(app.router.routes):
        concrete = getattr(entry, "starlette_route", None) or entry
        path = getattr(concrete, "path", "") or getattr(entry, "path", "")
        if isinstance(concrete, Mount):
            table.append(RouteInfo(path, frozenset(), frozenset(), concrete.app, "mount"))
            continue
        methods = getattr(concrete, "methods", None)
        dependant = getattr(concrete, "dependant", None) or getattr(entry, "dependant", None)
        table.append(
            RouteInfo(
                path=path,
                methods=frozenset(methods or ()),
                dependencies=frozenset(_dependency_names(dependant, set())) if dependant else frozenset(),
                endpoint=getattr(concrete, "endpoint", None) or getattr(entry, "endpoint", None),
                kind="http" if methods else "ws",
            )
        )
    return table


def test_route_table_is_enumerated(app: FastAPI) -> None:
    table = route_table(app)
    v1 = [r for r in table if r.path.startswith("/v1/") and r.kind == "http"]
    assert len(v1) > 60, "expected the full plugin route table"
    assert any(r.kind == "ws" and r.path == "/v1/devices/channel" for r in table)


def test_every_v1_route_requires_a_device_session(app: FastAPI) -> None:
    unguarded = [
        f"{sorted(r.methods)} {r.path}"
        for r in route_table(app)
        if r.kind == "http"
        and r.path.startswith("/v1/")
        and not r.path.startswith(PUBLIC_PREFIXES)
        and r.path not in OAUTH_CALLBACKS
        and "require_device" not in r.dependencies
    ]
    assert unguarded == [], "routes without require_device:\n" + "\n".join(unguarded)


def test_exemption_lists_are_not_stale(app: FastAPI) -> None:
    paths = {r.path for r in route_table(app)}
    assert paths >= OAUTH_CALLBACKS
    assert paths >= SELF_AUTHENTICATING


async def test_unauthenticated_requests_are_refused(app: FastAPI, client: httpx.AsyncClient) -> None:
    """Dynamic check of the same rule: every guarded route answers 401 without a token."""
    refused: list[str] = []
    for r in route_table(app):
        if r.kind != "http" or not r.path.startswith("/v1/") or r.path.startswith(PUBLIC_PREFIXES):
            continue
        if r.path in OAUTH_CALLBACKS:
            continue
        url = re.sub(r"\{[^}]+\}", "x_probe", r.path)
        for method in sorted(r.methods - {"HEAD", "OPTIONS"}):
            response = await client.request(method, url)
            if response.status_code != 401:
                refused.append(f"{method} {r.path} -> {response.status_code}")
    assert refused == [], "\n".join(refused)


@pytest.mark.parametrize("path", sorted(OAUTH_CALLBACKS))
async def test_oauth_callbacks_reject_unknown_state(client: httpx.AsyncClient, path: str) -> None:
    url = path.replace("{provider_id}", "swiggy_instamart")
    response = await client.get(url, params={"code": "probe-code", "state": "never-issued"})
    # 4xx (bad state) or 503 (integration not configured): never a success or a redirect onward
    assert response.status_code >= 400, response.text


def test_device_channel_refuses_without_token(app: FastAPI) -> None:
    # Not `with TestClient(app)`: that would run the app's lifespan a second time, on the client's own
    # event loop, while the `app` fixture already runs it on the test loop (engine and MCP session
    # managers shared across two loops can hang at shutdown).
    http = TestClient(app)
    with pytest.raises(WebSocketDisconnect) as refused, http.websocket_connect("/v1/devices/channel"):
        pass
    assert refused.value.code == 1008


async def test_mounted_apps_refuse_without_token(app: FastAPI, client: httpx.AsyncClient) -> None:
    mounts = [r for r in route_table(app) if r.kind == "mount"]
    for mount in mounts:
        response = await client.post(
            f"{mount.path}/memory-mcp",
            json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            headers={"accept": "application/json, text/event-stream"},
        )
        assert response.status_code in (401, 403, 404), f"{mount.path}: {response.status_code}"
        assert response.status_code != 200


def _body_kinds(dependant: Any, out: list[str]) -> list[str]:
    for param in getattr(dependant, "body_params", []) or []:
        info = getattr(param, "field_info", None)
        out.append(
            f"{type(info).__name__}:{getattr(param, 'type_', None) or getattr(info, 'annotation', None)}"
        )
    for sub in getattr(dependant, "dependencies", []) or []:
        _body_kinds(sub, out)
    return out


def test_no_route_accepts_image_uploads_for_photo_search(app: FastAPI) -> None:
    """Photos are indexed and searched on the device; the backend never receives the images."""
    offenders: list[str] = []
    checked = 0
    for entry in _walk(app.router.routes):
        concrete = getattr(entry, "starlette_route", None) or entry
        path = getattr(concrete, "path", "") or getattr(entry, "path", "")
        if not re.search(r"photo|vision|image", path, re.I):
            continue
        checked += 1
        dependant = getattr(concrete, "dependant", None) or getattr(entry, "dependant", None)
        kinds = _body_kinds(dependant, [])
        if any(
            k.startswith(("File:", "Form:")) or "UploadFile" in k or k.endswith(":<class 'bytes'>")
            for k in kinds
        ):
            offenders.append(f"{path}: {kinds}")
    assert checked >= 1, "expected the vision / photo routes"
    assert offenders == [], "photo search must not accept image uploads:\n" + "\n".join(offenders)


def test_body_kind_detector_sees_uploads() -> None:
    router = APIRouter()

    @router.post("/photos/upload")
    async def upload(file: UploadFile) -> None:
        return None

    kinds = _body_kinds(router.routes[0].dependant, [])  # type: ignore[attr-defined]
    assert any(k.startswith("File:") for k in kinds), kinds
