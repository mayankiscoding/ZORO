"""Journeys that end on a device: an alarm on the asking phone, a photo search, a WhatsApp
message with a contact lookup and an approval, and music on the paired Mac."""

from __future__ import annotations

from typing import Any

from app.core.types import ApprovalLevel, DevicePlatform, RiskLevel
from app.plugins import PluginRegistry
from tests.integration.flows.conftest import Attach, ExternalGateway, Phone, in_order

PRIYA = {
    "contact_ref": "c-priya",
    "name": "Priya Sharma",
    "phones": ["+91 98765 43210"],
    "emails": ["priya@example.test"],
}
PRIYA_WORK = {"contact_ref": "c-priya-2", "name": "Priya Nair", "phones": ["+91 91234 56789"], "emails": []}


# ---------------------------------------------------------------- (b) alarm


async def test_alarm_runs_on_the_asking_phone(phone: Phone, gateway: ExternalGateway) -> None:
    phone.on_device["ios.alarm.create"] = lambda args: {"alarm_id": "alarm-1"}
    turn = await phone.ask("set an alarm for 7 AM")

    assert phone.ran == [("ios.alarm.create", {"time": "07:00", "label": None, "repeat_days": None})]
    assert in_order(
        turn.kinds,
        "turn_started", "route", "tool_started", "device_action", "turn_suspended",
        "tool_finished", "text_delta", "turn_completed",
    )  # fmt: skip
    finished = turn.of("tool_finished")[-1]
    assert finished["ok"] is True
    assert turn.text == "Alarm set." and finished["summary"] == "Alarm set."  # the spoken confirmation
    assert turn.of("route")[0]["engine"] == "deterministic" and gateway.requests == []


# ---------------------------------------------------------------- (c) photo search


async def test_photo_search_runs_on_the_phone_and_shows_a_card(
    phone: Phone, gateway: ExternalGateway
) -> None:
    seen: list[dict[str, Any]] = []

    def search(args: dict[str, Any]) -> dict[str, Any]:
        seen.append(args)
        return {
            "hits": [
                {
                    "asset_id": "A1B2/L0/001",
                    "captured_at": "2026-11-12T17:05:00+05:30",
                    "score": 0.91,
                    "labels": ["cap", "person"],
                    "matched": ["color:blue", "label:cap"],
                }
            ],
            "indexed_count": 4210,
            "limited_library": False,
        }

    phone.on_device["device.photos.search"] = search
    turn = await phone.ask("find the photo from yesterday with my blue cap")

    # parse (backend) -> device.photos.search (the phone) -> vision.show_photo_results (backend)
    assert turn.tools == ["vision.parse_photo_query", "device.photos.search", "vision.show_photo_results"]
    query = seen[0]["query"]
    assert query["date_from"] == query["date_to"] == "2026-11-12"  # yesterday, in the owner's time zone
    assert query["colors"] == ["blue"] and "cap" in query["labels"]
    # The card is updated as the chain moves on: searching, then the results.
    assert {card["kind"] for card in turn.cards} == {"photo_query"}
    assert turn.cards[0]["payload"]["state"] == "searching"
    final = turn.cards[-1]["payload"]
    assert final["asset_ids"] == ["A1B2/L0/001"] and final["hits"][0]["labels"] == ["cap", "person"]
    assert "matched" not in final["hits"][0]  # text recognised in images is never passed on
    assert turn.completed and gateway.requests == []
    assert turn.text == "Found 1 matching photos on your iPhone."  # the last step speaks for the chain


# ---------------------------------------------------------------- (d) WhatsApp


async def test_whatsapp_message_one_match_needs_a_signed_high_approval(
    phone: Phone, registry: PluginRegistry, gateway: ExternalGateway
) -> None:
    phone.on_device["device.contacts.find"] = lambda args: {"matches": [PRIYA]}
    phone.on_device["device.whatsapp.compose"] = lambda args: {"opened": True}

    turn = await phone.ask("send a WhatsApp message to Priya saying I'll be ten minutes late")

    # The contact lookup ran on the phone; nothing has been composed yet.
    assert phone.ran == [("device.contacts.find", {"query": "Priya"})]
    approval = turn.approval
    assert approval is not None and approval.tool == "device.whatsapp.compose"
    assert approval.risk is RiskLevel.HIGH and approval.level is ApprovalLevel.CONFIRM
    shown = " ".join([approval.title, approval.summary, *[f"{d.label} {d.value}" for d in approval.details]])
    assert "Priya Sharma" in shown and "+919876543210" in shown and "I'll be ten minutes late" in shown
    assert approval.tainted is False
    pending = (await phone.client.get("/v1/approvals/pending", headers=phone.device.headers)).json()
    assert [item["approval_id"] for item in pending["items"]] == [approval.approval_id]

    done = await phone.approve(turn)
    assert phone.ran[-1] == (
        "device.whatsapp.compose",
        {"phone": "919876543210", "text": "I'll be ten minutes late", "recipient_name": "Priya Sharma"},
    )
    assert done.completed and "WhatsApp" in done.text
    assert in_order(
        done.kinds,
        "turn_started", "route", "device_action", "turn_suspended", "approval_required",
        "turn_suspended", "device_action", "turn_suspended", "text_delta", "turn_completed",
    )  # fmt: skip
    assert gateway.requests == []
    audit = await registry.service("audit").list(limit=200)
    assert any(r.action == "approval.decided" and r.decision == "approved" for r in audit.items)


async def test_whatsapp_message_declined_composes_nothing(phone: Phone) -> None:
    phone.on_device["device.contacts.find"] = lambda args: {"matches": [PRIYA]}
    turn = await phone.ask("send a WhatsApp message to Priya saying I'll be ten minutes late")
    done = await phone.approve(turn, approved=False)
    assert done.completed and [tool for tool, _ in phone.ran] == ["device.contacts.find"]


async def test_whatsapp_message_two_matches_asks_which_one(phone: Phone) -> None:
    phone.on_device["device.contacts.find"] = lambda args: {"matches": [PRIYA, PRIYA_WORK]}
    turn = await phone.ask("send a WhatsApp message to Priya saying I'll be ten minutes late")

    assert turn.completed and turn.of("approval_required") == []  # nothing to approve yet
    assert [tool for tool, _ in phone.ran] == ["device.contacts.find"]
    assert "Priya Sharma" in turn.text and "Priya Nair" in turn.text and "?" in turn.text


# ---------------------------------------------------------------- (e) on my Mac


async def test_music_asked_from_the_phone_plays_on_the_paired_mac(
    phone: Phone, attach: Attach, gateway: ExternalGateway
) -> None:
    mac = await attach(name="Test Mac", platform=DevicePlatform.MACOS)
    mac.on_device["device.music.control"] = lambda args: {
        "now_playing": {"title": "Weightless", "artist": "Marconi Union", "provider": "apple_music"}
    }
    phone.on_device["device.music.control"] = lambda args: {"now_playing": None}

    turn = await phone.ask("play something relaxing on my Mac")

    assert turn.completed, turn.kinds
    assert phone.ran == []  # the phone could have played it, but the owner said "on my Mac"
    ((tool, args),) = mac.ran
    assert tool == "device.music.control" and args["action"] in ("play", "search_play")
    assert turn.of("device_action") == []  # dispatched over the Mac's channel, not the phone's stream
    assert gateway.requests == []


async def test_music_on_the_mac_when_the_mac_is_offline_says_so(phone: Phone, pair_device: Any) -> None:
    await pair_device(name="Test Mac", platform=DevicePlatform.MACOS)  # paired, no channel open
    phone.on_device["device.music.control"] = lambda args: {"now_playing": None}
    turn = await phone.ask("play something relaxing on my Mac")
    assert turn.completed and phone.ran == []  # never falls back to the phone silently
    failed = [event for event in turn.of("tool_finished") if not event["ok"]]
    assert failed and failed[-1]["summary"] == "device_offline"


async def test_a_delivered_action_with_no_answer_is_an_unknown_outcome_and_is_not_retried(
    phone: Phone, attach: Attach, registry: PluginRegistry
) -> None:
    mac = await attach(name="Test Mac", platform=DevicePlatform.MACOS)
    mac.answer = False  # it receives the action and never answers
    spec = registry.tools.get("device.music.control")
    assert spec is not None
    object.__setattr__(spec, "timeout_s", 0.2)  # keep the wait short for the test
    turn = await phone.ask("play something relaxing on my Mac")

    delivered = [frame for frame in mac.frames if frame["type"] == "device_action"]
    assert len(delivered) == 1  # delivered once, never sent again
    failed = [event for event in turn.of("tool_finished") if not event["ok"]]
    assert failed[-1]["summary"] == "device_timeout"
    audit = await registry.service("audit").list(limit=200)
    assert any("device_timeout outcome_unknown" in record.detail for record in audit.items)
