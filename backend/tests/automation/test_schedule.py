"""Schedule computation with a fixed clock, trigger validation, and the bounded scheduler."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from pydantic import ValidationError

from app.automation.runner import RoutineRunner
from app.automation.schedule import next_run_after
from app.automation.scheduler import RoutineScheduler
from app.automation.schemas import RoutineIn, Trigger
from app.automation.service import RoutineService
from app.core.clock import FixedClock
from app.plugins import PluginRegistry
from tests.automation.conftest import NOW

IST = "Asia/Kolkata"


def at(y: int, mo: int, d: int, h: int, mi: int = 0) -> datetime:
    return datetime(y, mo, d, h, mi, tzinfo=UTC)


# 06:30 UTC is 12:00 on Friday 13 Nov 2026 in India.


def test_daily_runs_today_if_the_time_is_ahead_else_tomorrow() -> None:
    daily = Trigger(kind="daily", time="18:30")  # 13:00 UTC
    assert next_run_after(daily, NOW, IST) == at(2026, 11, 13, 13, 0)
    morning = Trigger(kind="daily", time="07:00")  # already past in India today
    assert next_run_after(morning, NOW, IST) == at(2026, 11, 14, 1, 30)
    exactly_now = Trigger(kind="daily", time="12:00")
    assert next_run_after(exactly_now, NOW, IST) == at(2026, 11, 14, 6, 30)  # strictly after


def test_weekly_picks_the_next_listed_day() -> None:
    mon_wed = Trigger(kind="weekly", days=["wed", "mon"], time="06:00")
    assert mon_wed.days == ["mon", "wed"]
    assert next_run_after(mon_wed, NOW, IST) == at(2026, 11, 16, 0, 30)  # Monday 16 Nov 06:00 IST
    friday = Trigger(kind="weekly", days=["fri"], time="18:00")
    assert next_run_after(friday, NOW, IST) == at(2026, 11, 13, 12, 30)  # today, still ahead
    friday_early = Trigger(kind="weekly", days=["fri"], time="08:00")
    assert next_run_after(friday_early, NOW, IST) == at(2026, 11, 20, 2, 30)  # next Friday


def test_interval_and_manual() -> None:
    assert next_run_after(Trigger(kind="interval", every_minutes=90), NOW, IST) == NOW + timedelta(minutes=90)
    assert next_run_after(Trigger(), NOW, IST) is None


def test_the_time_zone_decides_the_day() -> None:
    late = at(2026, 11, 13, 20, 0)  # 01:30 Saturday in India, 15:00 Friday in New York
    daily = Trigger(kind="daily", time="09:00")
    assert next_run_after(daily, late, IST) == at(2026, 11, 14, 3, 30)
    assert next_run_after(daily, late, "America/New_York") == at(2026, 11, 14, 14, 0)
    assert next_run_after(daily, late, "Mars/Olympus") == next_run_after(
        daily, late, IST
    )  # unknown zone: India


def test_daylight_saving_keeps_the_local_time() -> None:
    daily = Trigger(kind="daily", time="09:00")
    before = next_run_after(daily, at(2026, 3, 6, 20, 0), "America/New_York")  # 7 Mar is EST, UTC-5
    after = next_run_after(
        daily, at(2026, 3, 8, 20, 0), "America/New_York"
    )  # 9 Mar is EDT (from 8 Mar), UTC-4
    assert before == at(2026, 3, 7, 14, 0) and after == at(2026, 3, 9, 13, 0)


@pytest.mark.parametrize(
    "bad",
    [
        {"kind": "daily"},
        {"kind": "daily", "time": "25:00"},
        {"kind": "daily", "time": "9:00"},
        {"kind": "weekly", "time": "08:00"},
        {"kind": "weekly", "days": [], "time": "08:00"},
        {"kind": "weekly", "days": ["funday"], "time": "08:00"},
        {"kind": "interval"},
        {"kind": "interval", "every_minutes": 5},
        {"kind": "interval", "every_minutes": 100000},
        {"kind": "manual", "time": "08:00"},
        {"kind": "daily", "time": "08:00", "every_minutes": 30},
        {"kind": "hourly"},
    ],
)
def test_invalid_triggers_are_refused(bad: dict[str, object]) -> None:
    with pytest.raises(ValidationError):
        Trigger.model_validate(bad)


# ---------------------------------------------------------------- scheduler


def routine(
    name: str, trigger: dict[str, object], *, enabled: bool = True, tool: str = "test.echo"
) -> RoutineIn:
    return RoutineIn.model_validate(
        {
            "name": name,
            "steps": [{"tool": tool, "args": {"text": name}}],
            "trigger": trigger,
            "enabled": enabled,
        }
    )


def parts(registry: PluginRegistry) -> tuple[RoutineService, RoutineRunner, RoutineScheduler]:
    return (
        registry.service("automation_routines"),
        registry.service("automation_runner"),
        registry.service("automation_scheduler"),
    )


async def test_saving_computes_the_next_run(registry: PluginRegistry) -> None:
    service, _, _ = parts(registry)
    saved = await service.save(routine("Evening", {"kind": "daily", "time": "18:30"}))
    assert saved.created and saved.next_run_at == at(2026, 11, 13, 13, 0)
    manual = await service.save(routine("Manual", {"kind": "manual"}))
    assert manual.next_run_at is None
    off = await service.save(routine("Off", {"kind": "daily", "time": "18:30"}, enabled=False))
    assert off.next_run_at is None and not off.enabled
    back = await service.set_enabled("Off", True)
    assert back.next_run_at == at(2026, 11, 13, 13, 0)


async def test_tick_runs_only_what_is_due_and_reschedules_first(
    registry: PluginRegistry, clock: FixedClock
) -> None:
    service, _, scheduler = parts(registry)
    await service.save(routine("Evening", {"kind": "daily", "time": "18:30"}))
    await service.save(routine("Manual", {"kind": "manual"}))
    assert await scheduler.tick() == []  # nothing due yet at 12:00
    clock.set(at(2026, 11, 13, 13, 1))  # 18:31 in India
    started = await scheduler.tick()
    assert len(started) == 1
    run = await service.get_run(started[0])
    assert run.status == "completed" and run.trigger_kind == "schedule" and run.routine_name == "Evening"
    after = await service.get("Evening")
    assert after.next_run_at == at(2026, 11, 14, 13, 0) and after.last_run_at == at(2026, 11, 13, 13, 1)
    assert await scheduler.tick() == []  # the same minute again: not fired twice


async def test_a_long_outage_skips_missed_runs_instead_of_firing_them(
    registry: PluginRegistry, clock: FixedClock
) -> None:
    service, _, scheduler = parts(registry)
    await service.save(routine("Evening", {"kind": "daily", "time": "18:30"}))
    clock.set(at(2026, 11, 16, 9, 0))  # the server was off for three days
    assert await scheduler.tick() == []
    again = await service.get("Evening")
    assert again.next_run_at == at(2026, 11, 16, 13, 0) and again.last_run_at == at(2026, 11, 16, 9, 0)
    assert await service.runs("Evening") == []


async def test_disabled_routines_and_the_kill_switch_do_not_run(
    registry: PluginRegistry, clock: FixedClock
) -> None:
    service, _, scheduler = parts(registry)
    await service.save(routine("Evening", {"kind": "daily", "time": "18:30"}))
    clock.set(at(2026, 11, 13, 13, 1))
    await service.set_enabled("Evening", False)
    assert await scheduler.tick() == []
    await service.set_enabled("Evening", True)
    clock.set(at(2026, 11, 14, 13, 1))
    await registry.service("kill_switch").set(True, actor="test")
    assert await scheduler.tick() == []  # paused while the kill switch is on
    await registry.service("kill_switch").set(False, actor="test")
    assert len(await scheduler.tick()) == 1


async def test_at_most_max_due_per_tick_and_one_active_run_per_routine(
    registry: PluginRegistry, clock: FixedClock
) -> None:
    service, runner, scheduler = parts(registry)
    scheduler.max_due_per_tick = 2
    for i in range(4):
        await service.save(routine(f"R{i}", {"kind": "interval", "every_minutes": 15}))
    clock.advance(delta=timedelta(minutes=16))
    assert len(await scheduler.tick()) == 2  # two now, two on the next tick
    assert len(await scheduler.tick()) == 2
    # a routine that is waiting for an approval is skipped, not started again
    scheduler.max_due_per_tick = 10
    await service.save(
        RoutineIn.model_validate(
            {
                "name": "Waits",
                "steps": [{"tool": "test.write", "args": {"note": "n"}}],
                "trigger": {"kind": "interval", "every_minutes": 15},
            }
        )
    )
    clock.advance(delta=timedelta(minutes=16))
    first = await scheduler.tick()
    waiting_run = [r for r in [await service.get_run(i) for i in first] if r.routine_name == "Waits"]
    assert waiting_run and waiting_run[0].status == "awaiting_approval"
    clock.advance(delta=timedelta(minutes=16))
    await runner.expire_waiting()  # the approval (5 minutes) has expired by now
    assert (await service.get_run(waiting_run[0].id)).status == "failed"


async def test_start_and_stop_through_the_plugin_hooks(
    registry: PluginRegistry, monkeypatch: pytest.MonkeyPatch
) -> None:
    _, _, scheduler = parts(registry)
    assert not scheduler.running  # switched off by the test environment
    monkeypatch.setenv("ZORO_AUTOMATION_SCHEDULER", "on")
    await registry.run_startup()  # the hook the app calls
    assert scheduler.running
    await registry.run_startup()  # starting twice does not start a second task
    await scheduler.stop()
    assert not scheduler.running
    await registry.run_shutdown()


def test_tick_interval_is_bounded_below(registry: PluginRegistry) -> None:
    assert RoutineScheduler(registry, registry.service("automation_runner"), tick_s=0.001).tick_s == 5.0
