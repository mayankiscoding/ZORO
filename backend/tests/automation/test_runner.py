"""The runner: approval gating, resume, templates, limits, failure paths."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import pytest
from pydantic import ValidationError
from sqlalchemy import select

from app.automation.models import RoutineRun
from app.automation.runner import RoutineRunner, RunLimits
from app.automation.schemas import RoutineIn, Step, Trigger
from app.automation.service import (
    RoutineBusy,
    RoutineDisabled,
    RoutineInvalid,
    RoutineNotFound,
    RoutineService,
    RunNotWaiting,
)
from app.core.clock import FixedClock
from app.core.types import AgentId
from app.plugins import PluginRegistry
from app.schemas.turns import DeviceActionResult
from tests.automation.conftest import NOW, Recorder
from tests.conftest import PairedDevice


def routine(name: str, *steps: tuple[str, dict[str, Any]], **extra: Any) -> RoutineIn:
    return RoutineIn.model_validate(
        {"name": name, "steps": [{"tool": t, "args": a} for t, a in steps], **extra}
    )


def parts(registry: PluginRegistry) -> tuple[RoutineService, RoutineRunner]:
    return registry.service("automation_routines"), registry.service("automation_runner")


async def test_low_steps_run_without_approval_and_templates_fill_in(registry: PluginRegistry) -> None:
    service, runner = parts(registry)
    await service.save(
        routine(
            "Greet",
            ("test.echo", {"text": "Hello {{params.who}} on {{now.date}} at {{now.time}}"}),
            ("test.echo", {"text": "{{steps.0.text}}!"}),
            ("test.echo", {"text": "n={{steps.0.size}}"}),
        )
    )
    run = await runner.start("greet", params={"who": "Asha"})
    assert run.status == "completed" and run.step_index == 3 and run.steps_total == 3
    assert [s.status for s in run.step_log] == ["completed"] * 3 and run.step_log[
        0
    ].summary == "test.echo done"
    async with registry.service("session_factory")() as session:
        row = (await session.scalars(select(RoutineRun))).one()
    assert row.finished_at and row.error is None and row.trigger_kind == "manual"
    results = runner._unseal(row)
    assert results[0]["text"] == "Hello Asha on 2026-11-13 at 12:00"  # India time, from the fixed clock
    assert results[1]["text"] == "Hello Asha on 2026-11-13 at 12:00!" and results[2]["text"] == "n=33"
    assert "Asha" not in (row.results_enc or "") and "Asha" not in str(
        row.step_log
    )  # results are sealed; history has summaries only


async def test_a_whole_placeholder_keeps_its_type(registry: PluginRegistry, test_tools: Recorder) -> None:
    service, runner = parts(registry)
    await service.save(
        routine(
            "Typed",
            ("test.echo", {"text": "abc"}),
            ("test.write", {"note": "n", "count": "{{steps.0.size}}"}),
        )
    )
    waiting = await runner.start("Typed")
    assert waiting.status == "awaiting_approval" and waiting.pending and waiting.pending.step == 1
    approvals = registry.service("approvals")
    pending = (await approvals.list_pending())[0]
    assert (
        '"count":3' in str(pending.summary) or "count: 3" in pending.summary
    )  # the integer 3, rendered from the earlier result


async def test_medium_steps_wait_for_the_owner_and_then_run_exactly_once(
    registry: PluginRegistry, paired_device: PairedDevice, test_tools: Recorder
) -> None:
    service, runner = parts(registry)
    await service.save(
        routine(
            "Notes",
            ("test.echo", {"text": "first"}),
            ("test.write", {"note": "buy milk"}),
            ("test.echo", {"text": "last"}),
        )
    )
    run = await runner.start("Notes", device_id=paired_device.device_id)
    assert run.status == "awaiting_approval" and run.step_index == 1 and test_tools.writes == []
    assert run.pending and run.pending.kind == "approval" and run.pending.level == "confirm"
    assert [s.status for s in run.step_log] == ["completed", "waiting"]
    request = (await registry.service("approvals").list_pending())[0]
    assert request.approval_id == run.pending.approval_id and "buy milk" in request.summary

    # a forged decision leaves the run waiting
    forged = paired_device.signer.sign_approval(request, action_digest="0" * 64)
    still = await runner.resume(run.id, device_id=paired_device.device_id, approval=forged)
    assert still.status == "awaiting_approval" and test_tools.writes == []

    decision = paired_device.signer.sign_approval(request)
    done = await runner.resume(run.id, device_id=paired_device.device_id, approval=decision)
    assert done.status == "completed" and done.step_index == 3
    assert [w.note for w in test_tools.writes] == ["buy milk"]
    assert [s.status for s in done.step_log] == ["completed", "completed", "completed"]
    again = await runner.resume(run.id, device_id=paired_device.device_id, approval=decision)
    assert (
        again.status == "completed" and len(test_tools.writes) == 1
    )  # replaying the decision changes nothing


async def test_declining_stops_the_run_and_nothing_is_written(
    registry: PluginRegistry, paired_device: PairedDevice, test_tools: Recorder
) -> None:
    service, runner = parts(registry)
    await service.save(routine("Notes", ("test.write", {"note": "x"}), ("test.echo", {"text": "after"})))
    run = await runner.start("Notes", device_id=paired_device.device_id)
    request = (await registry.service("approvals").list_pending())[0]
    out = await runner.resume(
        run.id,
        device_id=paired_device.device_id,
        approval=paired_device.signer.sign_approval(request, approved=False),
    )
    assert out.status == "failed" and out.error == "approval_declined" and test_tools.writes == []
    assert out.step_log[-1].status == "denied" and out.finished_at


async def test_an_expired_approval_fails_the_run(
    registry: PluginRegistry, clock: FixedClock, test_tools: Recorder
) -> None:
    service, runner = parts(registry)
    await service.save(routine("Notes", ("test.write", {"note": "x"})))
    run = await runner.start("Notes")
    assert run.status == "awaiting_approval" and run.pending and run.pending.expires_at
    assert await runner.expire_waiting() == 0
    clock.advance(delta=timedelta(minutes=6))
    assert await runner.expire_waiting() == 1
    final = await service.get_run(run.id)
    assert final.status == "failed" and final.error == "approval_expired" and test_tools.writes == []
    assert (await service.runs("Notes"))[0].id == run.id


async def test_user_initiated_is_false_inside_a_run_even_when_the_owner_asked_for_the_run(
    registry: PluginRegistry, test_tools: Recorder
) -> None:
    service, _ = parts(registry)
    await service.save(routine("Notes", ("test.write", {"note": "x"})))
    ctx = registry.tool_context(turn_id="t1", agent=AgentId.AUTOMATION, user_initiated=True)
    direct = await registry.service("tool_executor").execute(
        ctx, "test.write", {"note": "direct"}, call_id="direct"
    )
    assert (
        type(direct).__name__ == "Completed"
    )  # the same MEDIUM tool runs at once when the owner asked in the turn
    via_run = await registry.service("tool_executor").execute(
        ctx, "automation.run_routine", {"routine": "Notes"}, call_id="viarun"
    )
    assert type(via_run).__name__ == "Completed" and via_run.result.status == "awaiting_approval"  # type: ignore[union-attr]
    assert [w.note for w in test_tools.writes] == ["direct"]


async def test_one_active_run_per_routine_and_a_disabled_routine_does_not_run(
    registry: PluginRegistry,
) -> None:
    service, runner = parts(registry)
    await service.save(routine("Notes", ("test.write", {"note": "x"})))
    first = await runner.start("Notes")
    with pytest.raises(RoutineBusy) as busy:
        await runner.start("Notes")
    assert busy.value.detail == {"run_id": first.id}
    cancelled = await runner.cancel(first.id)
    assert cancelled.status == "cancelled" and (await runner.cancel(first.id)).status == "cancelled"
    await service.set_enabled("Notes", False)
    with pytest.raises(RoutineDisabled):
        await runner.start("Notes")
    with pytest.raises(RoutineNotFound):
        await runner.start("nope")


async def test_resume_needs_a_waiting_run_and_the_matching_payload(
    registry: PluginRegistry, paired_device: PairedDevice
) -> None:
    service, runner = parts(registry)
    await service.save(routine("Notes", ("test.write", {"note": "x"})))
    run = await runner.start("Notes")
    with pytest.raises(RunNotWaiting):
        await runner.resume(run.id, device_id=paired_device.device_id)  # no decision supplied
    await runner.cancel(run.id)
    assert (await runner.resume(run.id, device_id=None)).status == "cancelled"


# ---------------------------------------------------------------- limits and failures


async def test_template_errors_and_missing_params_stop_the_run(registry: PluginRegistry) -> None:
    service, runner = parts(registry)
    await service.save(routine("Needs", ("test.echo", {"text": "{{params.who}}"})))
    run = await runner.start("Needs")
    assert (
        run.status == "failed"
        and run.error
        and run.error.startswith("template:")
        and run.step_log[0].status == "failed"
    )
    for bad, message in (
        ({"text": "{{secrets.key}}"}, "unknown placeholder"),
        ({"text": "{{steps.0.text}}"}, "earlier step"),
        ({"text": "{{now.century}}"}, "unknown placeholder"),
        ({"text": "{{ broken"}, "malformed"),
        ({"text": "x" * 9000}, "larger than"),
    ):
        with pytest.raises(
            ValidationError, match=message
        ):  # refused by the request model, before any approval
            routine("Bad", ("test.echo", bad))
        loose = RoutineIn.model_construct(
            name="Bad",
            description="",
            steps=[Step(tool="test.echo", args=bad)],
            trigger=Trigger(),
            enabled=True,
            timezone="Asia/Kolkata",
        )
        with pytest.raises(
            RoutineInvalid, match=message
        ):  # and again by the service, for callers that skip it
            await service.save(loose)


async def test_steps_are_validated_when_saved_and_when_run(registry: PluginRegistry) -> None:
    service, runner = parts(registry)
    for steps, message in (
        ([("test.missing", {})], "no tool named"),
        ([("test.other_agent", {})], "may not call"),
        ([("automation.run_routine", {"routine": "x"})], "cannot call"),
        ([("automation.save_routine", {})], "cannot call"),
        ([("test.write", {"nope": 1})], "do not fit"),
        ([("test.echo", {})] * 11, "1 to 10 steps"),
    ):
        data = RoutineIn.model_construct(
            name="Bad",
            description="",
            steps=[Step(tool=t, args=a) for t, a in steps],
            trigger=Trigger(),
            enabled=True,
            timezone="Asia/Kolkata",
        )
        with pytest.raises(RoutineInvalid, match=message):
            await service.save(data)
    with pytest.raises(Exception):  # noqa: B017 - the request model itself caps the steps at ten
        routine("Many", *[("test.echo", {})] * 11)
    await service.save(routine("Fine", ("test.echo", {"text": "a"})))
    registry.tools._tools.pop("test.echo")
    with pytest.raises(RoutineInvalid, match="no tool named"):
        await runner.start("Fine")


async def test_a_failing_tool_ends_the_run_with_its_error(registry: PluginRegistry) -> None:
    service, runner = parts(registry)
    await service.save(
        routine("Breaks", ("test.echo", {"text": "a"}), ("test.boom", {}), ("test.echo", {"text": "never"}))
    )
    run = await runner.start("Breaks")
    assert run.status == "failed" and run.error == "unavailable" and run.step_index == 1
    assert [s.status for s in run.step_log] == ["completed", "failed"]


async def test_step_timeout(registry: PluginRegistry) -> None:
    service, runner = parts(registry)
    runner.limits = RunLimits(step_timeout_s=0.05)
    await service.save(routine("Slow", ("test.slow", {}), ("test.echo", {"text": "never"})))
    run = await runner.start("Slow")
    assert run.status == "failed" and run.error == "step_timeout" and run.step_index == 0


async def test_run_time_limit_counts_active_time_only(registry: PluginRegistry) -> None:
    service, runner = parts(registry)
    runner.limits = RunLimits(step_timeout_s=1.0, run_time_limit_s=0.07)
    await service.save(
        routine("Long", ("test.nap", {}), ("test.nap", {}), ("test.nap", {}), ("test.nap", {}))
    )
    run = await runner.start("Long")
    assert run.status == "timed_out" and run.error == "run_time_limit" and 1 <= run.step_index < 4


async def test_waiting_for_an_approval_does_not_use_up_the_time_limit(
    registry: PluginRegistry, paired_device: PairedDevice, clock: FixedClock, test_tools: Recorder
) -> None:
    service, runner = parts(registry)
    runner.limits = RunLimits(run_time_limit_s=5.0)
    await service.save(routine("Notes", ("test.write", {"note": "x"}), ("test.echo", {"text": "after"})))
    run = await runner.start("Notes", device_id=paired_device.device_id)
    clock.advance(delta=timedelta(minutes=2))  # far longer than the limit, but spent waiting
    request = (await registry.service("approvals").list_pending())[0]
    done = await runner.resume(
        run.id, device_id=paired_device.device_id, approval=paired_device.signer.sign_approval(request)
    )
    assert done.status == "completed" and len(test_tools.writes) == 1


async def test_untrusted_output_taints_the_rest_of_the_run(
    registry: PluginRegistry, test_tools: Recorder
) -> None:
    service, runner = parts(registry)
    await service.save(routine("Reads", ("test.untrusted", {}), ("test.write", {"note": "x"})))
    run = await runner.start("Reads")
    assert run.status == "awaiting_approval" and test_tools.untrusted_calls == 1
    async with registry.service("session_factory")() as session:
        assert (await session.scalars(select(RoutineRun))).one().tainted is True


async def test_the_kill_switch_stops_a_run_at_the_policy_engine(registry: PluginRegistry) -> None:
    service, runner = parts(registry)
    await service.save(routine("Greet", ("test.echo", {"text": "a"})))
    await registry.service("kill_switch").set(True, actor="test")
    run = await runner.start("Greet")
    assert run.status == "failed" and run.error == "kill_switch"


async def test_history_is_pruned_and_stale_runs_are_closed(
    registry: PluginRegistry, clock: FixedClock, monkeypatch: pytest.MonkeyPatch
) -> None:
    import app.automation.service as svc

    service, runner = parts(registry)
    monkeypatch.setattr(svc, "MAX_RUNS_KEPT", 3)
    await service.save(routine("Greet", ("test.echo", {"text": "a"})))
    for _ in range(5):
        clock.advance(seconds=1)
        await runner.start("Greet")
    assert len(await service.runs("Greet", 50)) == 3
    async with registry.service("session_factory")() as session:
        stale = RoutineRun(
            id="run_stale",
            routine_id="rtn_x",
            routine_name="x",
            status="running",
            trigger_kind="manual",
            steps=[],
            params={},
            step_log=[],
            tainted=False,
            lang="en",
            timezone="Asia/Kolkata",
            active_s=0.0,
            started_at=NOW,
            updated_at=NOW,
        )
        session.add(stale)
        await session.commit()
    clock.advance(delta=timedelta(minutes=10))
    assert await runner.recover_stale() == 1
    assert (await service.get_run("run_stale")).status == "timed_out"


# ---------------------------------------------------------------- device steps


async def test_a_device_step_waits_for_the_device_result(
    registry: PluginRegistry, paired_device: PairedDevice, test_tools: Recorder
) -> None:
    service, runner = parts(registry)
    await service.save(routine("Ping", ("test.device", {"label": "hi"}), ("test.echo", {"text": "after"})))
    run = await runner.start("Ping", device_id=paired_device.device_id)
    assert run.status == "awaiting_device" and run.pending and run.pending.kind == "device"
    assert (
        run.pending.request
        and run.pending.request["tool"] == "test.device"
        and run.pending.request["args"] == {"label": "hi"}
    )
    result = DeviceActionResult(
        action_id=run.pending.action_id or "", ok=True, result={"ok": True}, executed_at=NOW
    )
    wrong = await runner.resume(run.id, device_id="dev_other", device_result=result)
    assert wrong.status == "awaiting_device"  # another device cannot answer for this one
    done = await runner.resume(run.id, device_id=paired_device.device_id, device_result=result)
    assert done.status == "completed" and done.step_index == 2
    refused = await runner.start("Ping", device_id=paired_device.device_id)
    failed = await runner.resume(
        refused.id,
        device_id=paired_device.device_id,
        device_result=DeviceActionResult(
            action_id=refused.pending.action_id or "",
            ok=False,
            error_code="permission_denied",
            executed_at=NOW,
        ),
    )  # type: ignore[union-attr]
    assert failed.status == "failed" and failed.error == "permission_denied"
