"""Tools through the executor: metadata, results, three-language summaries, cards, refusals."""

from __future__ import annotations

import re
from datetime import timedelta
from typing import Any

import pytest

from app.core.clock import FixedClock
from app.core.types import AgentId, DataClass, RiskLevel
from app.fitness.schemas import SyncIn
from app.plugins import PluginRegistry
from app.tools.outcome import Completed, Denied, Failed
from tests.fitness.conftest import make_ctx
from tests.fitness.data import TODAY, payload, run, series

TOOLS = {
    "fitness.daily_summary": {},
    "fitness.weekly_comparison": {},
    "fitness.trends": {"metric": "steps", "days": 28},
    "fitness.running_progress": {},
    "fitness.personal_records": {},
    "fitness.consistency": {"weeks": 4},
    "fitness.build_running_plan": {"goal": "10k", "days_per_week": 4},
    "fitness.build_routine": {"goal": "strength", "days_per_week": 4, "equipment": "dumbbells"},
    "fitness.music_hint": {"workout_type": "running"},
}
_NUM = re.compile(r"\d+(?:\.\d+)?")


async def seed(registry: PluginRegistry) -> None:
    days = series(
        35,
        steps=lambda i: 6000 + 100 * i,
        walking_running_distance_m=lambda i: 4000 + 50 * i,
        active_energy_kcal=lambda i: 300 + i,
        exercise_minutes=lambda i: 30 if i % 3 == 0 else 10,
        resting_heart_rate_bpm=lambda i: 64 if i >= 32 else 58,
        sleep_minutes=lambda i: 330 if i >= 32 else 420,
    )
    runs = [run(f"hk-{i}", TODAY - timedelta(days=60 - 4 * i + 20), 5.0, 400.0 - 4 * i) for i in range(12)]
    await registry.service("fitness_store").apply_sync(SyncIn.model_validate(payload(days, runs)))
    await registry.service("permissions").set("health.read", True)


async def call(
    registry: PluginRegistry, tool: str, args: dict[str, Any], lang: str = "en", cid: str = "c"
) -> Completed:
    outcome = await registry.service("tool_executor").execute(
        make_ctx(registry, lang=lang), tool, args, call_id=f"{tool}-{lang}-{cid}"
    )
    assert isinstance(outcome, Completed), outcome
    return outcome


def numbers(value: Any) -> set[float]:
    found: set[float] = set()
    if isinstance(value, bool):
        return found
    if isinstance(value, int | float):
        found.add(float(value))
    elif isinstance(value, str):
        found |= {float(n) for n in _NUM.findall(value)}
    elif isinstance(value, dict):
        for inner in value.values():
            found |= numbers(inner)
    elif isinstance(value, list):
        for inner in value:
            found |= numbers(inner)
    return found


def test_metadata_is_static_and_complete(registry: PluginRegistry) -> None:
    specs = {t.name: t for t in registry.tools if t.name.startswith("fitness.")}
    assert set(specs) == set(TOOLS)
    for spec in specs.values():
        assert spec.risk is RiskLevel.LOW and spec.data_classes == frozenset({DataClass.HEALTH})
        assert (
            spec.permission == "health.read"
            and spec.mcp_group == "fitness-mcp"
            and spec.executor == "backend"
        )
        assert AgentId.FITNESS in spec.agents and spec.summarizer and spec.card
        assert not spec.untrusted_output
    assert (
        AgentId.MUSIC in specs["fitness.music_hint"].agents
        and AgentId.SHOPPING not in specs["fitness.daily_summary"].agents
    )


@pytest.mark.parametrize("lang", ["en", "hi", "hinglish"])
async def test_every_answer_states_source_freshness_and_only_result_numbers(
    registry: PluginRegistry, clock: FixedClock, lang: str
) -> None:
    await seed(registry)
    clock.advance(delta=timedelta(hours=3))
    for tool, args in TOOLS.items():
        done = await call(registry, tool, args, lang)
        text = done.summary or ""
        assert text and "\n" not in text and len(text) < 420, (tool, text)
        result = done.result.model_dump(mode="json")
        assert result["available"] is True
        if tool in ("fitness.build_running_plan", "fitness.build_routine", "fitness.music_hint"):
            assert (
                {"en": "based on", "hi": "आधारित", "hinglish": "par based"}[lang] in text
            ) or "Apple Health" in text, text
        else:
            assert "Apple Health" in text, text
            assert (
                "3" in text
                and {
                    "en": "synced 3 hours ago",
                    "hi": "3 घंटे पहले सिंक हुआ",
                    "hinglish": "3 ghante pehle sync hua",
                }[lang]
                in text
            )
        if lang == "hi":
            assert re.search("[ऀ-ॿ]", text), text
        pool = numbers(result)
        for token in _NUM.findall(text):
            assert float(token) in pool, (tool, lang, token, text)
        assert done.card is not None and done.card.kind == "fitness_summary"
        assert done.card.payload["data_source"] and "freshness" in done.card.payload
        assert (
            result["freshness"]["age_value"] == 3
            and result["freshness"]["age_unit"] == "hours"
            and result["freshness"]["stale"] is False
        )


async def test_results_match_the_synced_series(registry: PluginRegistry) -> None:
    await seed(registry)
    daily = (await call(registry, "fitness.daily_summary", {})).result
    assert daily.steps == 6000 + 100 * 34 and daily.sleep_hours == 5.5 and daily.date == TODAY  # type: ignore[attr-defined]
    assert {o.code for o in daily.observations} >= {"rhr_above_baseline", "short_sleep_run"}  # type: ignore[attr-defined]
    done = await call(registry, "fitness.daily_summary", {}, "en", "again")
    assert "heart rate" in (done.summary or "") and "bpm" in (
        done.summary or ""
    )  # the observation is spoken too
    assert done.card and done.card.payload["observations"]
    yesterday = (
        await call(registry, "fitness.daily_summary", {"date": (TODAY - timedelta(days=1)).isoformat()})
    ).result
    assert yesterday.steps == 6000 + 100 * 33  # type: ignore[attr-defined]
    trend = (await call(registry, "fitness.trends", {"metric": "steps", "days": 28})).result
    assert trend.direction == "up" and trend.slope_per_week == pytest.approx(700.0)  # type: ignore[attr-defined]


async def test_no_data_is_stated_never_filled_in(registry: PluginRegistry) -> None:
    await registry.service("permissions").set("health.read", True)
    for tool in (
        "fitness.daily_summary",
        "fitness.weekly_comparison",
        "fitness.trends",
        "fitness.running_progress",
        "fitness.personal_records",
        "fitness.consistency",
    ):
        for lang in ("en", "hi", "hinglish"):
            done = await call(registry, tool, TOOLS[tool], lang)
            result = done.result.model_dump(mode="json")
            assert result["available"] is False and result["reason"] == "never_synced", tool
            assert result["freshness"]["stale"] is True and result["freshness"]["last_synced_at"] is None
            assert done.summary and ("iPhone" in done.summary) and done.card is None
    # a plan still works without data and says so
    plan = await call(registry, "fitness.build_running_plan", {"goal": "first_5k"})
    assert plan.result.plan.start_basis == "assumed"  # type: ignore[attr-defined]
    assert "assumed" in (plan.summary or "")


async def test_partial_data_reasons(registry: PluginRegistry) -> None:
    await registry.service("permissions").set("health.read", True)
    await registry.service("fitness_store").apply_sync(SyncIn.model_validate(payload(series(5, steps=1000))))
    trend = await call(registry, "fitness.trends", {"metric": "steps", "days": 28})
    assert trend.result.reason == "not_enough_data" and "Only 5 days" in (trend.summary or "")  # type: ignore[attr-defined]
    missing = await call(registry, "fitness.daily_summary", {"date": "2026-01-01"})
    assert missing.result.reason == "no_data_for_date"  # type: ignore[attr-defined]
    running = await call(registry, "fitness.running_progress", {})
    assert running.result.reason == "no_running_data"  # type: ignore[attr-defined]


async def test_plan_uses_synced_running_volume(registry: PluginRegistry) -> None:
    await seed(registry)
    runs = [run(f"recent-{i}", TODAY - timedelta(days=2 + 7 * i), 6.0, 360.0) for i in range(4)]
    await registry.service("fitness_store").apply_sync(
        SyncIn.model_validate(payload([], runs, "2026-11-13T13:00:00+05:30"))
    )
    done = await call(registry, "fitness.build_running_plan", {"goal": "10k"})
    plan = done.result.plan  # type: ignore[attr-defined]
    assert plan.start_basis == "synced_runs" and plan.start_weekly_km == 6.0  # 24 km over the last 28 days
    assert done.result.data_source.startswith("Apple Health")  # type: ignore[attr-defined]
    explicit = await call(registry, "fitness.build_running_plan", {"goal": "10k", "current_weekly_km": 20})
    assert explicit.result.plan.start_basis == "user_provided"  # type: ignore[attr-defined]


async def test_music_hint_uses_recent_pace_when_none_given(registry: PluginRegistry) -> None:
    await seed(registry)
    hint = (await call(registry, "fitness.music_hint", {"workout_type": "running"})).result.hint  # type: ignore[attr-defined]
    assert any("average over your last runs" in line for line in hint.assumptions)
    given = (await call(registry, "fitness.music_hint", {"workout_type": "yoga"})).result.hint  # type: ignore[attr-defined]
    assert given.energy == "low"


async def test_refusals(registry: PluginRegistry) -> None:
    await seed(registry)
    executor = registry.service("tool_executor")
    await registry.service("permissions").set("health.read", False)
    denied = await executor.execute(make_ctx(registry), "fitness.daily_summary", {}, call_id="d1")
    assert isinstance(denied, Denied) and denied.reason.startswith("permission_not_granted")
    await registry.service("permissions").set("health.read", True)
    wrong_agent = await executor.execute(
        make_ctx(registry, agent=AgentId.SHOPPING), "fitness.daily_summary", {}, call_id="d2"
    )
    assert isinstance(wrong_agent, Denied) and wrong_agent.reason == "agent_not_allowed"
    bad = await executor.execute(
        make_ctx(registry), "fitness.trends", {"metric": "mood", "days": 28}, call_id="d3"
    )
    assert isinstance(bad, Failed) and bad.error == "invalid_arguments"
    short = await executor.execute(
        make_ctx(registry), "fitness.trends", {"metric": "steps", "days": 3}, call_id="d4"
    )
    assert isinstance(short, Failed) and short.error == "invalid_arguments"
    # LOW tools run for system-initiated work too (no approval)
    ok = await executor.execute(
        make_ctx(registry, user_initiated=False), "fitness.daily_summary", {}, call_id="d5"
    )
    assert isinstance(ok, Completed)


async def test_stale_data_is_flagged(registry: PluginRegistry, clock: FixedClock) -> None:
    await seed(registry)
    clock.advance(delta=timedelta(days=3))
    done = await call(registry, "fitness.weekly_comparison", {})
    fresh = done.result.freshness  # type: ignore[attr-defined]
    assert fresh.stale and (fresh.age_value, fresh.age_unit) == (3, "days")
    assert "synced 3 days ago" in (done.summary or "")
