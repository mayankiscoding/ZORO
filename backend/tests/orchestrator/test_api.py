"""HTTP surface: SSE framing, resume and cancel routes, history pages, retention, privacy mode."""

from __future__ import annotations

import json
from datetime import timedelta
from typing import Any

import httpx
import pytest

from app.core.clock import FixedClock
from app.core.errors import NotFound
from app.core.types import PrivacyMode
from app.plugins import PluginRegistry
from tests.conftest import PairedDevice
from tests.fakes.gateway import FakeGateway
from tests.orchestrator.conftest import Ask, cloud_mode
from tests.orchestrator.toolkit import Toolbox


def body(text: str, **extra: Any) -> dict[str, Any]:
    return {"input": {"text": text}, "client": {"platform": "ios"}, **extra}


def frames(response: httpx.Response) -> list[tuple[str, dict[str, Any]]]:
    """Parse `event: <type>` / `data: <json>` frames separated by a blank line."""
    out: list[tuple[str, dict[str, Any]]] = []
    for block in response.text.split("\n\n"):
        if not block:
            continue
        lines = block.split("\n")
        assert len(lines) == 2 and lines[0].startswith("event: ") and lines[1].startswith("data: ")
        out.append((lines[0][len("event: ") :], json.loads(lines[1][len("data: ") :])))
    return out


async def test_turn_stream_is_sse(
    client: httpx.AsyncClient, paired_device: PairedDevice, box: Toolbox
) -> None:
    response = await client.post(
        "/v1/turns", json=body("how much did I spend"), headers=paired_device.headers
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")
    assert response.headers["cache-control"] == "no-cache"
    assert response.text.endswith("\n\n")
    events = frames(response)
    assert events[0][0] == "turn_started" and events[-1][0] == "turn_completed"
    assert all(name == data["type"] for name, data in events)  # the frame name is the event type
    card = next(data for name, data in events if name == "card")
    assert card["card"] == {"kind": "finance_summary", "title": "2026-10", "payload": {"total": "12450.50"}}
    done = events[-1][1]
    assert done["usage"]["cost_usd"] == "0" and done["cloud_voice_allowed"] is False


async def test_turn_routes_need_a_paired_device(client: httpx.AsyncClient, box: Toolbox) -> None:
    assert (await client.post("/v1/turns", json=body("hi"))).status_code == 401
    assert (await client.get("/v1/conversations")).status_code == 401
    assert (await client.post("/v1/turns/turn_x/cancel")).status_code == 401


async def test_resume_and_cancel_over_http(
    client: httpx.AsyncClient, paired_device: PairedDevice, box: Toolbox
) -> None:
    headers = paired_device.headers
    started = frames(
        await client.post("/v1/turns", json=body("send a message to Asha saying on my way"), headers=headers)
    )
    assert [name for name, _ in started][-2:] == ["approval_required", "turn_suspended"]
    turn_id = started[0][1]["turn_id"]
    pending = await client.get("/v1/approvals/pending", headers=headers)
    assert [item["approval_id"] for item in pending.json()["items"]] == [
        started[-2][1]["approval"]["approval_id"]
    ]

    from app.schemas.turns import ApprovalRequest

    approval = ApprovalRequest.model_validate(started[-2][1]["approval"])
    decision = paired_device.signer.sign_approval(approval).model_dump(mode="json")
    resumed = await client.post(f"/v1/turns/{turn_id}/resume", json={"approval": decision}, headers=headers)
    assert resumed.status_code == 200 and resumed.headers["content-type"].startswith("text/event-stream")
    assert [name for name, _ in frames(resumed)] == ["tool_finished", "text_delta", "turn_completed"]
    assert box.calls["send"] == 1

    again = await client.post(f"/v1/turns/{turn_id}/resume", json={"approval": decision}, headers=headers)
    assert again.status_code == 409 and again.json()["code"] == "turn_not_suspended"
    empty = await client.post(f"/v1/turns/{turn_id}/resume", json={}, headers=headers)
    assert empty.status_code == 400 and empty.json()["code"] == "resume_invalid"
    missing = await client.post("/v1/turns/turn_nope/resume", json={"approval": decision}, headers=headers)
    assert missing.status_code == 404 and missing.json()["code"] == "turn_not_found"

    cancelled = await client.post(f"/v1/turns/{turn_id}/cancel", headers=headers)
    assert cancelled.json() == {"turn_id": turn_id, "status": "completed"}
    waiting = frames(await client.post("/v1/turns", json=body("set an alarm for 7:10"), headers=headers))
    other = waiting[0][1]["turn_id"]
    assert (await client.post(f"/v1/turns/{other}/cancel", headers=headers)).json()["status"] == "cancelled"
    assert (await client.post("/v1/turns/turn_nope/cancel", headers=headers)).status_code == 404


async def test_client_may_only_tighten_the_privacy_mode(
    client: httpx.AsyncClient, paired_device: PairedDevice, box: Toolbox, gateway: FakeGateway,
    registry: PluginRegistry,
) -> None:  # fmt: skip
    headers = paired_device.headers
    looser = frames(
        await client.post(
            "/v1/turns", json=body("find some songs", privacy_mode="cloud_intelligence"), headers=headers
        )
    )
    assert (
        looser[0][1]["privacy_mode"] == "strict_private"
    )  # the server is strict: asking for cloud is ignored
    assert gateway.requests == [] and looser[-1][1]["cloud_voice_allowed"] is False

    await cloud_mode(registry)
    stricter = frames(
        await client.post(
            "/v1/turns", json=body("find some songs", privacy_mode="strict_private"), headers=headers
        )
    )
    assert stricter[0][1]["privacy_mode"] == "strict_private"
    assert gateway.requests == [] and stricter[-1][1]["cloud_voice_allowed"] is False

    gateway.push("Three songs found, first Lag Ja Gale.")
    default = frames(await client.post("/v1/turns", json=body("find some songs"), headers=headers))
    assert default[0][1]["privacy_mode"] == PrivacyMode.CLOUD_INTELLIGENCE.value
    assert default[-1][1]["cloud_voice_allowed"] is True and len(gateway.requests) == 1


async def test_history_pagination_and_delete(
    client: httpx.AsyncClient, paired_device: PairedDevice, box: Toolbox, clock: FixedClock,
    registry: PluginRegistry,
) -> None:  # fmt: skip
    headers = paired_device.headers
    conversation_ids: list[str] = []
    for text in ("how much did I spend", "find some songs", "search for milk"):
        started = frames(await client.post("/v1/turns", json=body(text), headers=headers))
        conversation_ids.append(started[0][1]["conversation_id"])
        clock.advance(60)
    first = conversation_ids[0]
    for text in ("find some songs", "kharcha batao"):
        await client.post("/v1/turns", json=body(text, conversation_id=first), headers=headers)
        clock.advance(60)

    page1 = (await client.get("/v1/conversations", params={"limit": 2}, headers=headers)).json()
    assert [item["id"] for item in page1["items"]] == [first, conversation_ids[2]]  # most recent first
    assert page1["items"][0]["title"] == "how much did I spend" and page1["items"][0]["message_count"] == 6
    assert page1["items"][0]["last_message_preview"].startswith("Aapne 2026-10 mein")
    page2 = (
        await client.get(
            "/v1/conversations", params={"limit": 2, "cursor": page1["next_cursor"]}, headers=headers
        )
    ).json()
    assert [item["id"] for item in page2["items"]] == [conversation_ids[1]] and page2["next_cursor"] is None
    bad = await client.get("/v1/conversations", params={"cursor": "%%%"}, headers=headers)
    assert bad.status_code == 400 and bad.json()["code"] == "invalid_cursor"

    seen: list[dict[str, Any]] = []
    cursor: str | None = None
    while True:
        params: dict[str, Any] = {"limit": 4, **({"cursor": cursor} if cursor else {})}
        page = (
            await client.get(f"/v1/conversations/{first}/messages", params=params, headers=headers)
        ).json()
        seen.extend(page["items"])
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert [m["role"] for m in seen] == ["user", "assistant"] * 3
    assert seen[0]["text"] == "how much did I spend" and seen[1]["agents"] == ["finance"]
    assert seen[1]["cards"][0]["kind"] == "finance_summary"
    assert [m["language"] for m in seen[4:]] == ["hinglish", "hinglish"]

    # Message text is encrypted at rest.
    from sqlalchemy import select

    from app.orchestrator.models import MessageRow

    async with registry.service("session_factory")() as session:
        stored = list((await session.scalars(select(MessageRow.text_enc))).all())
    assert stored and all("spend" not in value and value.startswith("v1.") for value in stored)

    assert (await client.delete(f"/v1/conversations/{first}", headers=headers)).status_code == 204
    assert (await client.get(f"/v1/conversations/{first}/messages", headers=headers)).status_code == 404
    assert (await client.delete(f"/v1/conversations/{first}", headers=headers)).status_code == 404
    left = (await client.get("/v1/conversations", headers=headers)).json()
    assert [item["id"] for item in left["items"]] == [conversation_ids[2], conversation_ids[1]]


async def test_retention_purge_removes_old_conversations_and_their_state(
    ask: Ask, box: Toolbox, clock: FixedClock, registry: PluginRegistry
) -> None:
    service = registry.service("turn_service")
    store = registry.service("conversations")
    state = registry.service("conversation_state")
    old = (await ask("search for milk"))[0]
    assert await state.working_set(old.conversation_id, "products")
    clock.advance(delta=timedelta(days=29))
    recent = (await ask("find some songs"))[0]
    assert await service.purge_expired() == 0  # 29 days old: kept

    clock.advance(delta=timedelta(days=2))
    assert await service.purge_expired() == 1
    listed = (await store.list_conversations()).items
    assert [item.id for item in listed] == [recent.conversation_id]
    with pytest.raises(NotFound):
        await store.list_messages(old.conversation_id)
    with pytest.raises(NotFound):
        await store.get_turn(old.turn_id)
    assert await state.get(old.conversation_id, "working_set:products") is None
    assert await service.purge_expired() == 0


async def test_kill_switch_closes_the_turn_api(
    client: httpx.AsyncClient, paired_device: PairedDevice, box: Toolbox, registry: PluginRegistry
) -> None:
    await registry.service("kill_switch").set(True)
    response = await client.post("/v1/turns", json=body("find some songs"), headers=paired_device.headers)
    assert response.status_code in (401, 503)  # sessions end with the switch; nothing runs either way
    assert "tracks" not in box.calls
