"""Strict private mode (no external inference, whatever the journey) and the kill switch (everything
stops; only auth and security answer)."""

from __future__ import annotations

from typing import Any

from app.core.types import DevicePlatform, PrivacyMode
from app.plugins import PluginRegistry
from tests.finance.samples import generic_csv
from tests.integration.flows.conftest import Attach, ExternalGateway, McpConnect, Phone
from tests.integration.flows.test_money_flows import STATEMENT

PRIYA = {"contact_ref": "c1", "name": "Priya Sharma", "phones": ["+919876543210"], "emails": []}


def device_tools(phone: Phone) -> None:
    phone.on_device.update(
        {
            "ios.alarm.create": lambda args: {"alarm_id": "alarm-1"},
            "device.photos.search": lambda args: {"hits": [], "indexed_count": 12, "limited_library": False},
            "device.contacts.find": lambda args: {"matches": [PRIYA]},
            "device.whatsapp.compose": lambda args: {"opened": True},
        }
    )


async def run_the_journeys(phone: Phone) -> list[Any]:
    await phone.client.post(
        "/v1/finance/imports",
        headers=phone.device.headers,
        files={"file": ("october.csv", generic_csv(STATEMENT), "text/csv")},
        data={"account_name": "Main"},
    )
    turns = [
        await phone.ask("how much did I spend on food last month"),
        await phone.ask("पिछले महीने खाने पर कितना खर्च हुआ"),
        await phone.ask("set an alarm for 7 AM"),
        await phone.ask("find the photo from yesterday with my blue cap"),
        await phone.ask("play something relaxing on my Mac"),
        await phone.approve(await phone.ask("send a WhatsApp message to Priya saying I'll be ten minutes late")),
        await phone.ask("remember that my sister's birthday is on 4 March"),
        await phone.ask("what do you think about the future of electric scooters in India"),
    ]
    assert all(turn.completed for turn in turns), [turn.kinds[-1] for turn in turns]
    return turns


# ---------------------------------------------------------------- (j) strict private


async def test_strict_private_mode_makes_zero_external_model_calls_across_the_journeys(
    phone: Phone, attach: Attach, gateway: ExternalGateway, registry: PluginRegistry
) -> None:
    assert await registry.service("privacy_state").get_mode() is PrivacyMode.STRICT_PRIVATE  # the default
    mac = await attach(name="Test Mac", platform=DevicePlatform.MACOS)
    mac.on_device["device.music.control"] = lambda args: {"now_playing": None}
    device_tools(phone)

    turns = await run_the_journeys(phone)

    assert gateway.requests == []  # nothing reached the (external) model, in any journey
    assert all(turn.of("turn_started")[0]["privacy_mode"] == "strict_private" for turn in turns)
    assert all(turn.of("turn_completed")[0]["cloud_voice_allowed"] is False for turn in turns)
    assert all(turn.of("turn_completed")[0]["usage"]["model_calls"] == 0 for turn in turns)
    assert all(turn.of("route")[0]["engine"] == "deterministic" for turn in turns)
    # The open question has no deterministic answer; ZORO says so instead of asking a cloud model.
    assert "privacy mode" in turns[-1].text
    egress = [r for r in (await registry.service("audit").list(limit=200)).items if r.action.startswith("egress")]
    assert all(record.decision != "allowed" for record in egress)


async def test_a_turn_may_ask_for_strict_mode_when_the_server_is_in_cloud_mode(
    phone: Phone, gateway: ExternalGateway, registry: PluginRegistry
) -> None:
    await registry.service("privacy_state").set_mode(PrivacyMode.CLOUD_INTELLIGENCE)
    gateway.push({"agent": "personal_assistant", "intent": None, "confidence": 0.4, "reason": "open"}, "Scooters!")
    cloud = await phone.ask("what do you think about the future of electric scooters in India")
    assert cloud.completed and len(gateway.requests) >= 1  # in cloud mode the model is asked
    asked = len(gateway.requests)

    body = {
        "input": {"text": "what do you think about the future of electric scooters in India"},
        "client": {"platform": "ios"},
        "privacy_mode": "strict_private",  # stricter for this turn only
    }
    response = await phone.client.post("/v1/turns", json=body, headers=phone.device.headers)
    assert response.status_code == 200 and '"privacy_mode":"strict_private"' in response.text
    assert len(gateway.requests) == asked  # not one more request


# ---------------------------------------------------------------- (k) kill switch


async def flip_kill_switch(phone: Phone, enabled: bool) -> None:
    proof = phone.device.signer.sign_proof("set_kill_switch", "true" if enabled else "false")
    response = await phone.client.post(
        "/v1/security/kill-switch",
        json={"enabled": enabled, "proof": proof.model_dump(mode="json")},
        headers=phone.device.headers,
    )
    assert response.status_code == 200 and response.json() == {"kill_switch": enabled}, response.text


async def test_the_kill_switch_stops_everything(
    phone: Phone, attach: Attach, mcp_connect: McpConnect, registry: PluginRegistry, gateway: ExternalGateway
) -> None:
    mac = await attach(name="Test Mac", platform=DevicePlatform.MACOS)
    device_tools(phone)
    waiting = await phone.ask("send a WhatsApp message to Priya saying I'll be ten minutes late")
    approval = waiting.approval
    assert approval is not None
    ran_before = list(phone.ran)

    await flip_kill_switch(phone, True)

    headers = phone.device.headers
    turn_body = {"input": {"text": "set an alarm for 7 AM"}, "client": {"platform": "ios"}}
    blocked = {
        "new turn": await phone.client.post("/v1/turns", json=turn_body, headers=headers),
        "resume": await phone.client.post(
            f"/v1/turns/{waiting.turn_id}/resume", json={"approval": phone.sign(approval)}, headers=headers
        ),
        "generic decision": await phone.client.post(
            f"/v1/approvals/{approval.approval_id}/decision", json=phone.sign(approval), headers=headers
        ),
        "pending approvals": await phone.client.get("/v1/approvals/pending", headers=headers),
        "capabilities": await phone.client.get("/v1/capabilities", headers=headers),
        "finance": await phone.client.get("/v1/finance/summary", headers=headers),
        "automations": await phone.client.get("/v1/automations", headers=headers),
        "mcp": await phone.client.post(
            "/mcp/finance-mcp", json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, headers=headers
        ),
    }
    for name, response in blocked.items():
        assert response.status_code in (401, 503), (name, response.status_code, response.text)
        assert response.json()["code"] in ("kill_switch_active", "token_invalid", "unauthorized"), name
    assert blocked["new turn"].json()["code"] == "kill_switch_active"
    assert blocked["mcp"].status_code == 503

    # Nothing ran: the approved-looking decision opened nothing, the Mac received nothing.
    assert phone.ran == ran_before and mac.ran == []
    executor = registry.service("tool_executor")
    ctx = registry.tool_context(turn_id="turn_killed", agent=_agent("finance"), device_id=phone.device.device_id)
    outcome = await executor.execute(ctx, "finance.spending_summary", {"period": "last_month"}, call_id="k1")
    assert type(outcome).__name__ == "Denied" and outcome.reason == "kill_switch"
    assert gateway.requests == []

    # Health and the security endpoints still answer (the way back).
    assert (await phone.client.get("/healthz")).status_code == 200
    state = await phone.client.get("/v1/security/state", headers=headers)
    assert state.status_code in (200, 401)


def _agent(name: str) -> Any:
    from app.core.types import AgentId

    return AgentId(name)
