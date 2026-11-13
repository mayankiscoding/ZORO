"""One way to answer any approval (`POST /v1/approvals/{id}/decision`): a suspended turn sending
an email, an MCP call, and an automation run. Plus what must never happen: a second send on a
replay, a send on a tampered digest, an approval that outlives its cancelled turn."""

from __future__ import annotations

import json
from typing import Any

import httpx

from app.core.clock import FixedClock
from app.core.types import ApprovalLevel, RiskLevel
from app.plugins import PluginRegistry
from app.schemas.turns import ApprovalRequest
from tests.communications import harness as mail
from tests.communications.conftest import GMAIL, seed_tokens
from tests.integration.flows.conftest import Attach, ExternalGateway, McpConnect, Phone, Turn

SEND = f"{GMAIL}/messages/send"


def sends() -> list[httpx.Request]:
    return [request for request in mail.SEEN if request.url.path.endswith("/messages/send")]


async def decide(phone: Phone, approval: ApprovalRequest, body: dict[str, Any]) -> httpx.Response:
    return await phone.client.post(
        f"/v1/approvals/{approval.approval_id}/decision", json=body, headers=phone.device.headers
    )


async def pending_ids(phone: Phone) -> list[str]:
    listed = await phone.client.get("/v1/approvals/pending", headers=phone.device.headers)
    assert listed.status_code == 200
    return [item["approval_id"] for item in listed.json()["items"]]


# ---------------------------------------------------------------- (g) email


async def test_email_is_sent_exactly_once_after_approval_never_on_replay_or_tampered_digest(
    phone: Phone, registry: PluginRegistry, clock: FixedClock, gateway: ExternalGateway
) -> None:
    mail.ENV.update(GOOGLE_OAUTH_CLIENT_ID="gclient", GOOGLE_OAUTH_CLIENT_SECRET="gsecret")
    await seed_tokens(registry, clock)
    mail.ROUTES[("POST", SEND)] = lambda request: httpx.Response(200, json={"id": "gm-1", "threadId": "th-1"})

    turn = await phone.ask("send an email to priya@example.com saying the report is ready")
    approval = turn.approval
    assert approval is not None and approval.tool == "communications.send_email"
    assert approval.risk is RiskLevel.HIGH and approval.level is ApprovalLevel.CONFIRM
    assert "priya@example.com" in approval.title and "the report is ready" in approval.summary.lower()
    assert sends() == []  # nothing leaves before the owner approves

    # A decision signed over another digest: refused, the request stays open, nothing is sent.
    forged = await decide(phone, approval, phone.sign(approval, action_digest="0" * 64))
    assert forged.status_code == 200, forged.text
    refused = forged.json()
    assert refused["owner"] == "turn" and refused["status"] == "suspended"
    error = next(event for event in refused["events"] if event["type"] == "error")
    assert error["code"] == "approval_digest_mismatch" and error["retryable"] is True
    assert sends() == [] and await pending_ids(phone) == [approval.approval_id]

    # A decision signed with the wrong key is refused the same way.
    wrong_key = await decide(phone, approval, phone.sign(approval, key="approval"))
    assert wrong_key.json()["status"] == "suspended" and sends() == []

    # The real decision, on the generic route: the email goes out once.
    decision = phone.sign(approval)
    approved = await decide(phone, approval, decision)
    assert approved.status_code == 200, approved.text
    result = approved.json()
    assert result["owner"] == "turn" and result["approved"] is True and result["status"] == "completed"
    resumed = Turn(result["events"])
    assert resumed.kinds[-1] == "turn_completed" and "priya@example.com" in resumed.text
    assert len(sends()) == 1
    raw = json.loads(sends()[0].content)["raw"]
    assert raw  # exactly the approved message; its content is checked in tests/communications

    # Replays: the same signed decision, on either route, sends nothing again.
    replay = await decide(phone, approval, decision)
    assert replay.status_code == 409 and replay.json()["code"] == "approval_replayed"
    again = await phone.client.post(
        f"/v1/turns/{turn.turn_id}/resume", json={"approval": decision}, headers=phone.device.headers
    )
    assert again.status_code == 409 and again.json()["code"] == "turn_not_suspended"
    assert len(sends()) == 1 and await pending_ids(phone) == []
    assert gateway.requests == []


async def test_declined_email_is_never_sent(
    phone: Phone, registry: PluginRegistry, clock: FixedClock
) -> None:
    mail.ENV.update(GOOGLE_OAUTH_CLIENT_ID="gclient", GOOGLE_OAUTH_CLIENT_SECRET="gsecret")
    await seed_tokens(registry, clock)
    turn = await phone.ask("send an email to priya@example.com saying the report is ready")
    approval = turn.approval
    assert approval is not None
    declined = await decide(phone, approval, phone.sign(approval, approved=False))
    assert declined.json()["status"] == "completed" and declined.json()["approved"] is False
    assert sends() == []


async def test_someone_elses_signed_decision_is_refused(phone: Phone, pair_device: Any) -> None:
    phone.on_device["device.contacts.find"] = lambda args: {
        "matches": [{"contact_ref": "c1", "name": "Priya Sharma", "phones": ["+919876543210"], "emails": []}]
    }
    turn = await phone.ask("send a WhatsApp message to Priya saying on my way")
    approval = turn.approval
    assert approval is not None
    other = await pair_device(name="Other iPhone")
    stolen = other.signer.sign_approval(approval).model_dump(mode="json")
    # posted with the phone's session but signed by another device
    refused = await decide(phone, approval, stolen)
    assert refused.status_code == 403 and refused.json()["code"] == "wrong_device"
    assert await pending_ids(phone) == [approval.approval_id]


async def test_cancelling_a_suspended_turn_withdraws_its_approval(phone: Phone) -> None:
    phone.on_device["device.contacts.find"] = lambda args: {
        "matches": [{"contact_ref": "c1", "name": "Priya Sharma", "phones": ["+919876543210"], "emails": []}]
    }
    turn = await phone.ask("send a WhatsApp message to Priya saying on my way")
    approval = turn.approval
    assert approval is not None and await pending_ids(phone) == [approval.approval_id]

    cancelled = await phone.client.post(f"/v1/turns/{turn.turn_id}/cancel", headers=phone.device.headers)
    assert cancelled.status_code == 200 and cancelled.json()["status"] == "cancelled"
    assert await pending_ids(phone) == []  # nothing stays listed for a turn that cannot run
    late = await decide(phone, approval, phone.sign(approval))
    assert late.status_code == 409 and late.json()["code"] == "approval_replayed"
    assert [tool for tool, _ in phone.ran] == ["device.contacts.find"]  # WhatsApp was never opened


# ---------------------------------------------------------------- (h) MCP


async def test_mcp_call_needing_approval_is_answered_on_the_generic_route(
    phone: Phone, attach: Attach, mcp_connect: McpConnect
) -> None:
    channel = await attach(device=phone.device)  # the phone's device channel
    channel.on_device["device.notification.schedule"] = lambda args: {"id": "ntf-1"}
    args = {"title": "Stand up", "body": "Stretch for two minutes"}

    async with mcp_connect("notification-mcp", phone.device.token) as mcp:
        first = await mcp.call_tool("device.notification.schedule", args)
        assert first.is_error and first.structured_content["error"] == "approval_required"
        approval_id = first.structured_content["approval_id"]
        assert channel.ran == []

        # No turn stream shows this request: it is pushed over the device channel and listed.
        (pushed,) = channel.approvals
        assert pushed.approval_id == approval_id and pushed.tool == "device.notification.schedule"
        assert "Stand up" in pushed.summary + pushed.title + " ".join(d.value for d in pushed.details)
        assert await pending_ids(phone) == [approval_id]

        decided = await decide(phone, pushed, phone.sign(pushed))
        assert decided.status_code == 200, decided.text
        body = decided.json()
        assert body["owner"] == "mcp" and body["status"] == "completed" and body["approved"] is True
        assert [tool for tool, _ in channel.ran] == ["device.notification.schedule"]  # ran on the phone

        done = await mcp.call_tool("device.notification.schedule", {**args, "_zoro_approval_id": approval_id})
        assert not done.is_error and done.structured_content == {"id": "ntf-1"}
    assert len(channel.ran) == 1  # the retry collected the result; it did not run again
    replay = await decide(phone, pushed, phone.sign(pushed))
    assert replay.status_code == 409 and replay.json()["code"] == "approval_replayed"


# ---------------------------------------------------------------- (i) automation


async def test_automation_routine_pauses_for_approval_and_continues_after_it(
    phone: Phone, attach: Attach, clock: FixedClock
) -> None:
    channel = await attach(device=phone.device)
    headers = phone.device.headers
    saved = await phone.client.post(
        "/v1/automations",
        headers=headers,
        json={
            "name": "Evening nudge",
            "steps": [
                {
                    "tool": "device.notification.schedule",
                    "args": {"title": "Wind down", "body": "Screens off"},
                }
            ],
        },
    )
    assert saved.status_code == 200, saved.text
    started = await phone.client.post(f"/v1/automations/{saved.json()['id']}/run", headers=headers)
    assert started.status_code == 200, started.text
    run = started.json()
    assert run["status"] == "awaiting_approval" and run["pending"]["kind"] == "approval"
    approval_id = run["pending"]["approval_id"]

    (pushed,) = channel.approvals  # pushed to the owner's online device, and listed
    assert pushed.approval_id == approval_id and pushed.level is ApprovalLevel.CONFIRM
    assert await pending_ids(phone) == [approval_id]

    decided = await decide(phone, pushed, phone.sign(pushed))
    assert decided.status_code == 200, decided.text
    body = decided.json()
    assert body["owner"] == "automation" and body["run_id"] == run["id"] and body["approved"] is True
    # The step is a device tool for the phone that started the run: the run now waits for it.
    assert body["status"] == "awaiting_device"
    action = body["result"]["pending"]["request"]
    assert action["tool"] == "device.notification.schedule" and action["args"]["title"] == "Wind down"

    finished = await phone.client.post(
        f"/v1/automations/runs/{run['id']}/resume",
        headers=headers,
        json={
            "device_result": {
                "action_id": action["action_id"],
                "ok": True,
                "result": {"id": "ntf-9"},
                "executed_at": clock.now().isoformat(),
            }
        },
    )
    assert finished.status_code == 200 and finished.json()["status"] == "completed", finished.text
    assert await pending_ids(phone) == []
