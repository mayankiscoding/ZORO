from __future__ import annotations

import base64
import json
from collections.abc import Callable, Iterator, Sequence
from datetime import UTC, datetime, timedelta
from email import message_from_bytes
from typing import Any

import httpx
import pytest

from app.communications.service import CommunicationService
from app.core.clock import FixedClock
from app.core.types import AgentId, PrivacyMode
from app.plugins import PluginRegistry
from app.tools.spec import ToolContext
from tests.communications import harness

Route = Callable[[httpx.Request], httpx.Response]
GMAIL = "gmail.googleapis.com/gmail/v1/users/me"
TOKEN = "oauth2.googleapis.com/token"
REVOKE = "oauth2.googleapis.com/revoke"


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("tests.communications.harness",)


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(datetime(2026, 11, 13, 10, 0, tzinfo=UTC))


@pytest.fixture(autouse=True)
def reset() -> Iterator[None]:
    harness.ENV.clear()
    harness.SEEN.clear()
    harness.ROUTES.clear()
    yield
    harness.ENV.clear()


@pytest.fixture
def env() -> dict[str, str]:
    return harness.ENV


@pytest.fixture
def seen() -> list[httpx.Request]:
    return harness.SEEN


@pytest.fixture
def route() -> Callable[[str, str, Route], None]:
    def _add(method: str, where: str, fn: Route) -> None:
        harness.ROUTES[(method, where)] = fn

    return _add


@pytest.fixture
def comms(registry: PluginRegistry) -> CommunicationService:
    service: CommunicationService = registry.service("communications")
    return service


async def seed_tokens(registry: PluginRegistry, clock: FixedClock, *, age: timedelta = timedelta(0)) -> None:
    record = {
        "state": "connected",
        "access_token": "AT-1",
        "refresh_token": "RT-1",
        "expires_at": (clock.now() + timedelta(hours=1)).isoformat(),
        "scope": "",
        "connected_at": (clock.now() - age).isoformat(),
    }
    await registry.service("secrets").put("google", json.dumps(record))
    await registry.service("google_oauth").state()


@pytest.fixture
async def connected(registry: PluginRegistry, clock: FixedClock, env: dict[str, str]) -> None:
    env["GOOGLE_OAUTH_CLIENT_ID"] = "gclient"
    env["GOOGLE_OAUTH_CLIENT_SECRET"] = "gsecret"
    await seed_tokens(registry, clock)


def ctx_for(registry: PluginRegistry, **overrides: Any) -> ToolContext:
    fields: dict[str, Any] = {
        "turn_id": "turn_comms",
        "agent": AgentId.COMMUNICATION,
        "conversation_id": "conv_comms",
        "user_initiated": True,
        "privacy_mode": PrivacyMode.STRICT_PRIVATE,
    }
    fields.update(overrides)
    return registry.tool_context(**fields)


def b64(text: str) -> str:
    return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")


def gmail_message(
    mid: str, thread: str, subject: str, sender: str, body: str, *, headers_only: bool = False, **extra: Any
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "headers": [
            {"name": "From", "value": sender},
            {"name": "To", "value": "me@example.com"},
            {"name": "Subject", "value": subject},
            {"name": "Date", "value": "Thu, 12 Nov 2026 10:00:00 +0000"},
        ]
    }
    if not headers_only:
        payload["mimeType"] = "multipart/mixed"
        payload["parts"] = [
            {"mimeType": "text/plain", "body": {"data": b64(body)}},
            *extra.pop("parts", []),
        ]
    return {
        "id": mid,
        "threadId": thread,
        "snippet": body[:40],
        "internalDate": "1794477600000",
        "labelIds": ["INBOX"],
        "payload": payload,
        **extra,
    }


def decode_raw(raw: str) -> tuple[dict[str, str], str]:
    """(headers, decoded text body) of a base64url MIME message sent to Gmail."""
    data = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
    msg = message_from_bytes(data)
    payload = msg.get_payload(decode=True)
    assert isinstance(payload, bytes)
    return dict(msg.items()), payload.decode("utf-8")
