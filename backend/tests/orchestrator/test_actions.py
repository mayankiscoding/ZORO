"""Approvals, device actions, taint, the kill switch, budgets and cancellation."""

from __future__ import annotations

import asyncio
from dataclasses import replace
from datetime import UTC, datetime
from typing import Any

import pytest

from app.core.errors import Conflict, KillSwitchActive
from app.core.types import AgentId, ApprovalLevel, PrivacyMode, RiskLevel, TurnStatus
from app.orchestrator.state import TurnLimits
from app.plugins import PluginRegistry
from app.providers.types import ChatResponse, ToolCall, Usage
from app.schemas.turns import DeviceActionResult, ResumeRequest
from app.security.sessions import AuthedDevice
from tests.conftest import PairDevice, PairedDevice
from tests.fakes.gateway import FakeGateway
from tests.orchestrator.conftest import Ask, cloud_mode, of, text_of, turn_request
from tests.orchestrator.toolkit import Toolbox

SEND = "send a message to Asha saying running ten minutes late"


async def resume(registry: PluginRegistry, turn_id: str, device: AuthedDevice, **answer: Any) -> list[Any]:
    stream = await registry.service("turn_service").resume(turn_id, ResumeRequest(**answer), device)
    return [event async for event in stream]


async def status(registry: PluginRegistry, turn_id: str) -> TurnStatus:
    turn = await registry.service("conversations").get_turn(turn_id)
    return TurnStatus(turn.status)


async def test_approval_suspends_then_resumes_and_executes_exactly_once(
    ask: Ask, box: Toolbox, registry: PluginRegistry, paired_device: PairedDevice, authed: AuthedDevice
) -> None:
    events = await ask(SEND)
    assert [e.type for e in events] == [
        "turn_started", "route", "agent_started", "agent_finished", "tool_started",
        "approval_required", "turn_suspended",
    ]  # fmt: skip
    turn_id = events[0].turn_id
    approval = of(events, "approval_required")[0].approval
    assert approval.level is ApprovalLevel.CONFIRM and approval.risk is RiskLevel.HIGH
    assert approval.tool == "test.send_message" and approval.agent is AgentId.COMMUNICATION
    assert {d.label: d.value for d in approval.details} == {"to": "Asha", "body": "running ten minutes late"}
    assert of(events, "turn_suspended")[0].reason == "approval"
    assert "send" not in box.calls and await status(registry, turn_id) is TurnStatus.SUSPENDED

    resumed = await resume(registry, turn_id, authed, approval=paired_device.signer.sign_approval(approval))
    assert [e.type for e in resumed] == ["tool_finished", "text_delta", "turn_completed"]
    assert resumed[0].ok and resumed[0].call_id == of(events, "tool_started")[0].call_id  # one stable call id
    assert text_of(resumed) == "Message sent to Asha."
    assert box.calls["send"] == 1 and await status(registry, turn_id) is TurnStatus.COMPLETED

    with pytest.raises(Conflict) as replay:  # answering again cannot run it a second time
        await resume(registry, turn_id, authed, approval=paired_device.signer.sign_approval(approval))
    assert replay.value.error_code == "turn_not_suspended" and box.calls["send"] == 1


async def test_rejected_approval_does_nothing(
    ask: Ask, box: Toolbox, registry: PluginRegistry, paired_device: PairedDevice, authed: AuthedDevice
) -> None:
    events = await ask("asha ko message bhejo to Asha saying aa raha hoon", language_hint="hinglish")
    approval = of(events, "approval_required")[0].approval
    decision = paired_device.signer.sign_approval(approval, approved=False)
    resumed = await resume(registry, events[0].turn_id, authed, approval=decision)
    assert [e.type for e in resumed] == ["tool_finished", "text_delta", "turn_completed"]
    assert resumed[0].ok is False and resumed[0].summary == "approval_declined"
    assert text_of(resumed) == "Theek hai, maine woh nahi kiya."
    assert "send" not in box.calls


async def test_wrong_signature_keeps_the_turn_waiting(
    ask: Ask, box: Toolbox, registry: PluginRegistry, paired_device: PairedDevice, authed: AuthedDevice
) -> None:
    events = await ask(SEND)
    turn_id = events[0].turn_id
    approval = of(events, "approval_required")[0].approval
    forged = paired_device.signer.sign_approval(approval, key="approval")  # confirm needs the auth key
    again = await resume(registry, turn_id, authed, approval=forged)
    assert [e.type for e in again] == ["error", "approval_required", "turn_suspended"]
    assert again[0].code == "invalid_signature" and again[0].retryable
    assert again[1].approval.approval_id == approval.approval_id
    assert "send" not in box.calls and await status(registry, turn_id) is TurnStatus.SUSPENDED

    tampered = paired_device.signer.sign_approval(approval, action_digest="0" * 64)
    assert (await resume(registry, turn_id, authed, approval=tampered))[0].code == "approval_digest_mismatch"

    with pytest.raises(Conflict) as mismatch:  # an answer for some other approval
        other = approval.model_copy(update={"approval_id": "apr_other"})
        await resume(registry, turn_id, authed, approval=paired_device.signer.sign_approval(other))
    assert mismatch.value.error_code == "resume_mismatch"

    good = await resume(registry, turn_id, authed, approval=paired_device.signer.sign_approval(approval))
    assert text_of(good) == "Message sent to Asha." and box.calls["send"] == 1


async def test_device_action_suspends_and_resumes(
    ask: Ask, box: Toolbox, registry: PluginRegistry, authed: AuthedDevice, paired_device: PairedDevice
) -> None:
    events = await ask("set an alarm for 6:45")
    assert [e.type for e in events][-3:] == ["tool_started", "device_action", "turn_suspended"]
    action = of(events, "device_action")[0].action
    assert action.tool == "test.set_alarm" and action.args == {"time": "6:45"}
    assert action.target_device_id == paired_device.device_id
    assert of(events, "turn_suspended")[0].reason == "device_action"
    turn_id = events[0].turn_id

    with pytest.raises(Conflict):  # the turn waits for a device result, not an approval
        await resume(
            registry, turn_id, authed, device_result=_result("act_wrong", {"alarm_id": "x", "time": "6:45"})
        )

    result = _result(action.action_id, {"alarm_id": "alarm_9", "time": "6:45"})
    resumed = await resume(registry, turn_id, authed, device_result=result)
    assert [e.type for e in resumed] == ["tool_finished", "text_delta", "turn_completed"]
    assert text_of(resumed) == "Alarm set for 6:45."

    failed_turn = await ask("set an alarm for 5:00")
    failed_action = of(failed_turn, "device_action")[0].action
    denied = DeviceActionResult(
        action_id=failed_action.action_id,
        ok=False,
        error_code="permission_denied",
        executed_at=datetime.now(UTC),
    )
    after = await resume(registry, failed_turn[0].turn_id, authed, device_result=denied)
    assert after[0].ok is False and text_of(after) == "The device has not been given permission for that."


def _result(action_id: str, payload: dict[str, Any]) -> DeviceActionResult:
    return DeviceActionResult(action_id=action_id, ok=True, result=payload, executed_at=datetime.now(UTC))


async def test_resume_from_another_paired_device(
    ask: Ask, box: Toolbox, registry: PluginRegistry, pair_device: PairDevice
) -> None:
    events = await ask(SEND)
    mac = await pair_device(name="Test Mac")
    mac_authed = await registry.service("sessions").authenticate(mac.token)
    approval = of(events, "approval_required")[0].approval
    resumed = await resume(
        registry, events[0].turn_id, mac_authed, approval=mac.signer.sign_approval(approval)
    )
    assert text_of(resumed) == "Message sent to Asha." and box.calls["send"] == 1


async def test_tainted_turn_raises_the_approval_level(
    ask: Ask, box: Toolbox, registry: PluginRegistry, paired_device: PairedDevice, authed: AuthedDevice
) -> None:
    # Untainted: a MEDIUM action the owner asked for runs directly.
    direct = await ask("remind me to call the bank")
    assert text_of(direct) == "Reminder set: call the bank." and not of(direct, "approval_required")

    # After reading a web page in the same turn, the same action needs a confirmation...
    tainted = await ask("read the page and remind me to call the bank")
    assert of(tainted, "route")[0].agents == [AgentId.BROWSER_RESEARCH, AgentId.DEVICE_CONTROL]
    approval = of(tainted, "approval_required")[0].approval
    assert approval.tool == "test.create_reminder" and approval.level is ApprovalLevel.CONFIRM
    assert box.calls["remind"] == 1
    resumed = await resume(
        registry, tainted[0].turn_id, authed, approval=paired_device.signer.sign_approval(approval)
    )
    assert text_of(resumed) == "I read https://example.test/timetable. Reminder set: call the bank."
    assert box.calls["remind"] == 2

    # ...and a HIGH-risk action needs the user-presence key.
    high = await ask(f"read the page and {SEND}")
    assert of(high, "approval_required")[0].approval.level is ApprovalLevel.BIOMETRIC


async def test_model_chosen_action_asks_the_owner(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry,
    paired_device: PairedDevice, authed: AuthedDevice,
) -> None:  # fmt: skip
    await cloud_mode(registry)
    gateway.push(
        {"agent": "device_control", "confidence": 0.8},
        ChatResponse(
            tool_calls=(ToolCall(id="c1", name="test__create_reminder", arguments={"title": "pay rent"}),)
        ),
        "I have asked to set a reminder to pay rent; it is waiting for you.",
    )
    events = await ask("don't let me forget the rent")
    queued_note = next(m for m in gateway.requests[2].messages if m.role == "tool").content
    assert '"status": "queued"' in queued_note
    approval = of(events, "approval_required")[0].approval  # MEDIUM, but a model chose it
    assert approval.level is ApprovalLevel.CONFIRM and "remind" not in box.calls
    resumed = await resume(
        registry, events[0].turn_id, authed, approval=paired_device.signer.sign_approval(approval)
    )
    assert box.calls["remind"] == 1 and "Reminder set: pay rent." in text_of(resumed)


async def test_kill_switch_blocks_turns_and_stops_running_work(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry,
    paired_device: PairedDevice, authed: AuthedDevice,
) -> None:  # fmt: skip
    kill = registry.service("kill_switch")
    assert (
        await registry.service("privacy_state").effective_mode(PrivacyMode.CLOUD_INTELLIGENCE)
    ) is PrivacyMode.STRICT_PRIVATE

    async def flip() -> None:
        await kill.set(True)

    box.kill_on_fetch = flip  # the switch is thrown while the turn is already running
    events = await ask("read the page and remind me to call the bank")
    assert "remind" not in box.calls and not of(events, "approval_required")
    assert "kill switch is on" in text_of(events).lower()
    assert of(events, "turn_completed")[0].cloud_voice_allowed is False

    with pytest.raises(KillSwitchActive):
        await ask("how much did I spend")
    assert gateway.requests == [] and "spending" not in box.calls

    # Thrown between accepting the turn and running it: the graph answers without tools or models.
    await kill.set(False)
    stream = await registry.service("turn_service").start(turn_request("how much did I spend"), authed)
    await kill.set(True)
    raced = [event async for event in stream]
    assert of(raced, "route")[0].agents == [AgentId.SECURITY] and not of(raced, "tool_started")
    assert "kill switch is on" in text_of(raced).lower() and "spending" not in box.calls

    await kill.set(False)
    suspended = await ask(SEND)
    await kill.set(True)
    approval = of(suspended, "approval_required")[0].approval
    with pytest.raises(KillSwitchActive):
        await resume(
            registry, suspended[0].turn_id, authed, approval=paired_device.signer.sign_approval(approval)
        )
    assert "send" not in box.calls


async def test_tool_call_budget_ends_the_turn_with_a_clear_message(
    ask: Ask, box: Toolbox, registry: PluginRegistry
) -> None:
    core = registry.service("supervisor").core
    core.limits = TurnLimits(max_tool_calls=1)
    events = await ask("how much did I spend and remind me to call the bank")
    assert box.calls == {"spending": 1}  # the queued action was not run
    assert text_of(events).endswith("needed more steps than I am allowed in one turn.")
    assert of(events, "turn_completed")
    turn = await registry.service("conversations").get_turn(events[0].turn_id)
    assert turn.status is TurnStatus.COMPLETED and turn.error_code == "tool_calls"


async def test_token_and_wall_clock_budgets(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    await cloud_mode(registry)
    core = registry.service("supervisor").core
    core.limits = TurnLimits(max_tokens=500)
    big = Usage(input_tokens=900, output_tokens=50)
    gateway.push(
        {"agent": "music", "confidence": 0.7},
        ChatResponse(
            tool_calls=(ToolCall(id="c1", name="test__find_tracks", arguments={"query": "x"}),), usage=big
        ),
    )
    events = await ask("something calm please")
    assert len(gateway.requests) == 2  # the loop stopped instead of calling the model again
    assert "used up the model budget" in text_of(events)

    core.limits = TurnLimits(max_seconds=0)
    slow = await ask("how much did I spend")
    assert "taking too long" in text_of(slow) and "spending" not in box.calls


async def test_agent_timeout_and_recursion_limit(ask: Ask, box: Toolbox, registry: PluginRegistry) -> None:
    catalog = registry.service("agents")
    catalog.override(replace(catalog.get(AgentId.PERSONAL_ASSISTANT), max_seconds=0.05))
    events = await ask("write a slow note")
    assert of(events, "agent_finished")[0].ok is False
    assert "one part of this request took too long" in text_of(events)

    registry.service("supervisor").core.limits = TurnLimits(recursion_limit=3)
    looped = await ask("how much did I spend")
    assert [e.type for e in looped][-1] == "error"
    assert looped[-1].code == "recursion_limit" and "too many steps" in looped[-1].message
    assert await status(registry, looped[0].turn_id) is TurnStatus.FAILED


async def test_cancel_running_and_suspended_turns(
    box: Toolbox, registry: PluginRegistry, authed: AuthedDevice, ask: Ask, paired_device: PairedDevice
) -> None:
    service = registry.service("turn_service")
    stream = await service.start(turn_request("write a slow note"), authed)
    events: list[Any] = []

    async def consume() -> None:
        async for event in stream:
            events.append(event)

    consumer = asyncio.create_task(consume())
    await asyncio.wait_for(box.slow_started.wait(), timeout=5)
    turn_id = events[0].turn_id
    assert await service.cancel(turn_id) is TurnStatus.CANCELLED
    await asyncio.wait_for(consumer, timeout=5)
    assert events[-1].type == "error" and events[-1].code == "cancelled"
    assert not of(events, "turn_completed")
    assert await service.cancel(turn_id) is TurnStatus.CANCELLED  # idempotent

    suspended = await ask(SEND)
    assert await service.cancel(suspended[0].turn_id) is TurnStatus.CANCELLED
    approval = of(suspended, "approval_required")[0].approval
    with pytest.raises(Conflict):
        await resume(
            registry, suspended[0].turn_id, authed, approval=paired_device.signer.sign_approval(approval)
        )
    assert "send" not in box.calls

    done = await ask("find some songs")
    assert await service.cancel(done[0].turn_id) is TurnStatus.COMPLETED  # finished turns are left alone


async def test_resume_uses_the_tighter_privacy_mode_of_now(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry,
    paired_device: PairedDevice, authed: AuthedDevice,
) -> None:  # fmt: skip
    await cloud_mode(registry)
    events = await ask("find some songs and set an alarm for 6:30")
    assert events[0].privacy_mode is PrivacyMode.CLOUD_INTELLIGENCE
    action = of(events, "device_action")[0].action
    await registry.service("privacy_state").set_mode(PrivacyMode.STRICT_PRIVATE)  # tightened while waiting
    result = _result(action.action_id, {"alarm_id": "a1", "time": "6:30"})
    resumed = await resume(registry, events[0].turn_id, authed, device_result=result)
    assert gateway.requests == []  # the reply is not sent to a cloud model any more
    assert text_of(resumed) == "I found 3 songs; the first is Lag Ja Gale. Alarm set for 6:30."
    assert of(resumed, "turn_completed")[0].cloud_voice_allowed is False
