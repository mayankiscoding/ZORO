"""End-to-end flows: the real app with every plugin loaded, driven through its HTTP API.

- the model gateway is the scripted `FakeGateway` (it behaves as an external provider, so in
  strict private mode nothing may reach it; `gateway.requests` proves it);
- the asking iPhone is an HTTP client: it reads the SSE stream, runs device actions with
  `Phone.on_device` and posts the result back, and signs approvals with its software keys;
- other devices (the Mac) are `SimDevice`s attached to the device hub exactly like a WebSocket
  channel: they receive `device_action` / `approval_required` frames and answer in-band;
- nothing touches the network. Sample data lives only here, under tests/.
"""

from __future__ import annotations

import json
import shutil
from collections.abc import AsyncIterator, Callable, Iterator, Sequence
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
import httpx2
import pytest
import yaml
from fastapi import FastAPI
from mcp import Client
from mcp.client.streamable_http import streamable_http_client

from app.core.clock import FixedClock
from app.core.settings import Settings
from app.core.types import DevicePlatform, PrivacyMode
from app.devices.hub import DeviceConnection, DeviceHub
from app.plugins import PLUGIN_MODULES, PluginRegistry
from app.providers.types import ChatRequest, ChatResponse, NoPermittedModel
from app.schemas.turns import ApprovalRequest
from tests.communications import harness as mail
from tests.conftest import PairDevice, PairedDevice
from tests.fakes.gateway import FakeGateway

# Friday 13 November 2026, 12:00 in Asia/Kolkata. "Last month" is October 2026.
NOW = datetime(2026, 11, 13, 6, 30, tzinfo=UTC)

REPO_CONFIG = Path(__file__).resolve().parents[4] / "config"

Responder = Callable[[dict[str, Any]], dict[str, Any]]


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    """Every production plugin. Communications is loaded through its test harness: the same
    package (`install`), with Gmail and Google OAuth on a mock transport, so nothing can reach
    the network."""
    return tuple(
        "tests.communications.harness" if name == "app.communications.plugin" else name
        for name in PLUGIN_MODULES
    )


@pytest.fixture(autouse=True)
def _reset_mail() -> Iterator[None]:
    for store in (mail.ENV, mail.SEEN, mail.ROUTES):
        store.clear()
    yield
    for store in (mail.ENV, mail.SEEN, mail.ROUTES):
        store.clear()


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    """The shipped `config/`, copied, with one change: paired devices may use every MCP group
    (the shipped file grants none until the owner lists a device)."""
    config_dir = tmp_path / "config"
    shutil.copytree(REPO_CONFIG, config_dir)
    mcp_file = config_dir / "mcp_servers.yaml"
    mcp = yaml.safe_load(mcp_file.read_text(encoding="utf-8"))
    mcp["gateway"]["default_groups"] = ["*"]
    mcp_file.write_text(yaml.safe_dump(mcp), encoding="utf-8")
    return Settings(
        _env_file=None,
        env="test",
        database_url=f"sqlite+aiosqlite:///{tmp_path / 'zoro.db'}",
        object_dir=tmp_path / "objects",
        local_dir=tmp_path / "local",
        config_dir=config_dir,
        secret_key=None,
        data_key=None,
    )


McpConnect = Callable[[str, str], AbstractAsyncContextManager[Client]]


@pytest.fixture
def mcp_connect(app: FastAPI) -> McpConnect:
    """`async with mcp_connect("notification-mcp", token) as mcp:` an MCP SDK client over
    Streamable HTTP, reaching the app in-process at `/mcp/<group>`."""

    @asynccontextmanager
    async def _connect(group: str, token: str) -> AsyncIterator[Client]:
        transport = httpx2.ASGITransport(app=app)
        headers = {"Authorization": f"Bearer {token}"}
        async with httpx2.AsyncClient(
            transport=transport, base_url="http://zoro.test", headers=headers
        ) as http:
            stream = streamable_http_client(f"http://zoro.test/mcp/{group}", http_client=http)
            async with Client(stream, mode="legacy", read_timeout_seconds=10) as mcp:
                yield mcp

    return _connect


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(NOW)


class ExternalGateway(FakeGateway):
    """The scripted gateway behaving as one external provider, as `decide_egress` treats it: in
    strict private mode it is not permitted and refuses every request (`refused`), so
    `requests` holds only what really went out to the model."""

    def __init__(self) -> None:
        super().__init__(permit=lambda task, classes, mode: mode is not PrivacyMode.STRICT_PRIVATE)
        self.refused: list[ChatRequest] = []

    async def chat(self, req: ChatRequest) -> ChatResponse:
        if req.privacy_mode is PrivacyMode.STRICT_PRIVATE:
            self.refused.append(req)
            raise NoPermittedModel(req.task)
        return await super().chat(req)


@pytest.fixture
def gateway(registry: PluginRegistry) -> ExternalGateway:
    """Every plugin is loaded, so the real gateway is registered; the scripted one replaces it."""
    fake = ExternalGateway()
    registry.replace("gateway", fake)
    return fake


def parse_sse(body: str) -> list[dict[str, Any]]:
    """`event: <type>` + `data: <json>` frames, in order. The JSON carries its own `type`."""
    events: list[dict[str, Any]] = []
    for frame in body.split("\n\n"):
        lines = [line for line in frame.split("\n") if line]
        if not lines:
            continue
        name = next(line[len("event: ") :] for line in lines if line.startswith("event: "))
        data = json.loads(next(line[len("data: ") :] for line in lines if line.startswith("data: ")))
        assert data["type"] == name, frame
        events.append(data)
    return events


@dataclass
class Turn:
    events: list[dict[str, Any]]

    @property
    def kinds(self) -> list[str]:
        return [event["type"] for event in self.events]

    def of(self, kind: str) -> list[dict[str, Any]]:
        return [event for event in self.events if event["type"] == kind]

    @property
    def text(self) -> str:
        return "".join(event["text"] for event in self.of("text_delta"))

    @property
    def turn_id(self) -> str:
        return str(self.of("turn_started")[0]["turn_id"])

    @property
    def conversation_id(self) -> str:
        return str(self.of("turn_started")[0]["conversation_id"])

    @property
    def tools(self) -> list[str]:
        return [event["tool"] for event in self.of("tool_started")]

    @property
    def cards(self) -> list[dict[str, Any]]:
        return [event["card"] for event in self.of("card")]

    @property
    def approval(self) -> ApprovalRequest | None:
        """The approval the turn is suspended on, when it ended that way."""
        if self.kinds[-1:] != ["turn_suspended"] or self.events[-1]["reason"] != "approval":
            return None
        return ApprovalRequest.model_validate(self.of("approval_required")[-1]["approval"])

    @property
    def completed(self) -> bool:
        return self.kinds[-1:] == ["turn_completed"]


@dataclass
class Phone:
    """The asking iPhone: starts turns over HTTP, runs its own device actions, signs approvals."""

    client: httpx.AsyncClient
    device: PairedDevice
    now: Callable[[], datetime]
    platform: DevicePlatform = DevicePlatform.IOS
    on_device: dict[str, Responder] = field(default_factory=dict)
    ran: list[tuple[str, dict[str, Any]]] = field(default_factory=list)  # (tool, args) it executed

    async def _post(self, path: str, body: dict[str, Any]) -> Turn:
        response = await self.client.post(path, json=body, headers=self.device.headers)
        assert response.status_code == 200, response.text
        assert response.headers["content-type"].startswith("text/event-stream")
        return Turn(parse_sse(response.text))

    async def ask(self, text: str, *, conversation_id: str | None = None, **input_extra: Any) -> Turn:
        """Run a turn to the point where it completes or needs the owner's approval. Device
        actions for this phone are executed (`on_device`) and their results posted back."""
        body = {
            "conversation_id": conversation_id,
            "input": {"text": text, **input_extra},
            "client": {"platform": self.platform.value, "timezone": "Asia/Kolkata"},
        }
        turn = await self._post("/v1/turns", body)
        return await self._run_device_actions(turn)

    async def _run_device_actions(self, turn: Turn) -> Turn:
        turn_id = turn.turn_id
        while turn.kinds[-1:] == ["turn_suspended"] and turn.events[-1]["reason"] == "device_action":
            action = turn.of("device_action")[-1]["action"]
            assert action["target_device_id"] == self.device.device_id
            self.ran.append((action["tool"], action["args"]))
            result = {
                "action_id": action["action_id"],
                "ok": True,
                "result": self.on_device[action["tool"]](action["args"]),
                "executed_at": self.now().isoformat(),
            }
            more = await self._post(f"/v1/turns/{turn_id}/resume", {"device_result": result})
            turn = Turn(turn.events + more.events)
        return turn

    def sign(self, approval: ApprovalRequest, approved: bool = True, **kw: Any) -> dict[str, Any]:
        return self.device.signer.sign_approval(approval, approved, **kw).model_dump(mode="json")

    async def approve(self, turn: Turn, approved: bool = True) -> Turn:
        """Answer the turn's approval on the turn's own resume route and keep going."""
        approval = turn.approval
        assert approval is not None, turn.kinds
        more = await self._post(
            f"/v1/turns/{turn.turn_id}/resume", {"approval": self.sign(approval, approved)}
        )
        return await self._run_device_actions(Turn(turn.events + more.events))


@dataclass
class SimDevice:
    """A paired device attached to the hub like a WebSocket channel."""

    hub: DeviceHub
    device: PairedDevice
    conn: DeviceConnection
    now: Callable[[], datetime]
    on_device: dict[str, Responder] = field(default_factory=dict)
    ran: list[tuple[str, dict[str, Any]]] = field(default_factory=list)
    frames: list[dict[str, Any]] = field(default_factory=list)
    answer: bool = True  # False: receive the action and stay silent (a delivered, unanswered action)

    async def receive(self, frame: dict[str, Any]) -> None:
        self.frames.append(frame)
        if frame["type"] != "device_action" or not self.answer:
            return
        action = frame["action"]
        self.ran.append((action["tool"], action["args"]))
        result = {
            "action_id": action["action_id"],
            "ok": True,
            "result": self.on_device[action["tool"]](action["args"]),
            "executed_at": self.now().isoformat(),
        }
        await self.hub.handle_text(self.conn, json.dumps({"type": "device_action_result", "result": result}))

    @property
    def approvals(self) -> list[ApprovalRequest]:
        return [
            ApprovalRequest.model_validate(frame["approval"])
            for frame in self.frames
            if frame["type"] == "approval_required"
        ]


@pytest.fixture
def phone(client: httpx.AsyncClient, paired_device: PairedDevice, clock: FixedClock) -> Phone:
    return Phone(client=client, device=paired_device, now=clock.now)


Attach = Callable[..., Any]


@pytest.fixture
def attach(registry: PluginRegistry, pair_device: PairDevice, clock: FixedClock) -> Attach:
    """`await attach(name=..., platform=...)` pairs a device (or takes `device=`) and opens its
    channel on the hub."""

    async def _attach(
        *,
        name: str = "Test Mac",
        platform: DevicePlatform = DevicePlatform.MACOS,
        device: PairedDevice | None = None,
    ) -> SimDevice:
        hub: DeviceHub = registry.service("device_hub")
        paired = device or await pair_device(name=name, platform=platform)
        authed = await registry.service("sessions").authenticate(paired.token)

        async def close(code: int, reason: str) -> None:
            sim.frames.append({"type": "closed", "code": code, "reason": reason})

        async def send(frame: dict[str, Any]) -> None:
            await sim.receive(frame)

        conn = DeviceConnection(
            device_id=authed.device_id,
            session_id=authed.session_id,
            platform=authed.platform,
            name=authed.name,
            send=send,
            close=close,
            connected_at=clock.now(),
            last_frame_at=clock.now(),
        )
        sim = SimDevice(hub=hub, device=paired, conn=conn, now=clock.now)
        await hub.connect(conn)
        await hub.handle_text(conn, json.dumps({"type": "hello", "capabilities": []}))
        return sim

    return _attach


def in_order(kinds: list[str], *expected: str) -> bool:
    """True when `expected` appear in `kinds` in this order (other events may sit between)."""
    position = 0
    for kind in kinds:
        if position < len(expected) and kind == expected[position]:
            position += 1
    return position == len(expected)
