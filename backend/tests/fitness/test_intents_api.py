"""Intent routing in three languages, and the /v1/fitness routes."""

from __future__ import annotations

from typing import Any

import httpx
import pytest

from app.fitness.intents import build_intents, classify
from app.plugins import PluginRegistry
from app.tools.intents import IntentContext, IntentRegistry
from tests.conftest import PairedDevice
from tests.fitness.conftest import NOW
from tests.fitness.data import payload, series
from tests.fitness.test_tools import seed


@pytest.fixture
def intents() -> IntentRegistry:
    reg = IntentRegistry()
    for spec in build_intents():
        reg.register(spec)
    return reg


def route(intents: IntentRegistry, text: str, lang: str) -> tuple[str, dict[str, Any]] | None:
    ctx = IntentContext(lang=lang, now=NOW)
    for spec in intents.all():
        slots = spec.extract(text, ctx)
        if slots is not None:
            return spec.name, slots
    return None


CASES: list[tuple[str, str, str, dict[str, Any]]] = [
    ("how many steps today", "en", "fitness.daily_summary", {}),
    ("how many steps yesterday", "en", "fitness.daily_summary", {"date": "2026-11-12"}),
    ("aaj kitne kadam chale", "hinglish", "fitness.daily_summary", {}),
    ("kal kitne kadam chale", "hinglish", "fitness.daily_summary", {"date": "2026-11-12"}),
    ("आज कितने कदम चले", "hi", "fitness.daily_summary", {}),
    ("कल की नींद कैसी रही", "hi", "fitness.daily_summary", {"date": "2026-11-12"}),
    ("compare this week with last week", "en", "fitness.weekly_comparison", {}),
    ("pichhle hafte se tulna karo", "hinglish", "fitness.weekly_comparison", {}),
    ("पिछले हफ़्ते से तुलना करो", "hi", "fitness.weekly_comparison", {}),
    ("sleep trend over the last 30 days", "en", "fitness.trends", {"metric": "sleep_hours", "days": 30}),
    ("mere kadam ka trend", "hinglish", "fitness.trends", {"metric": "steps"}),
    ("नींद का ट्रेंड बताओ", "hi", "fitness.trends", {"metric": "sleep_hours"}),
    ("how is my running progress", "en", "fitness.running_progress", {}),
    ("meri running kaisi chal rahi hai", "hinglish", "fitness.running_progress", {}),
    ("मेरी रनिंग की प्रगति कैसी है", "hi", "fitness.running_progress", {}),
    ("what are my personal bests", "en", "fitness.personal_records", {}),
    ("meri sabse lambi run kaunsi thi", "hinglish", "fitness.personal_records", {}),
    ("मेरे रिकॉर्ड बताओ", "hi", "fitness.personal_records", {}),
    ("what is my workout streak", "en", "fitness.consistency", {}),
    ("kitne din workout kiya pichhle 4 hafte", "hinglish", "fitness.consistency", {"weeks": 4}),
    ("मेरी स्ट्रीक कितनी है", "hi", "fitness.consistency", {}),
    (
        "build me a 10k plan, 4 days a week for 12 weeks",
        "en",
        "fitness.build_running_plan",
        {"goal": "10k", "days_per_week": 4, "weeks": 12},
    ),
    ("5k ka running plan banao", "hinglish", "fitness.build_running_plan", {"goal": "5k"}),
    ("मेरे लिए रनिंग प्लान बनाओ", "hi", "fitness.build_running_plan", {}),
    (
        "make me a running plan, I run 15 km a week",
        "en",
        "fitness.build_running_plan",
        {"current_weekly_km": 15.0},
    ),
    (
        "make me a 4 day gym routine with dumbbells",
        "en",
        "fitness.build_routine",
        {"equipment": "dumbbells", "days_per_week": 4},
    ),
    ("workout plan banao 45 minute ka", "hinglish", "fitness.build_routine", {"minutes": 45}),
    ("जिम रूटीन बनाओ", "hi", "fitness.build_routine", {}),
    ("music for my run", "en", "fitness.music_hint", {"workout_type": "running"}),
    ("yoga ke liye workout music", "hinglish", "fitness.music_hint", {"workout_type": "yoga"}),
    ("वर्कआउट के लिए गाने", "hi", "fitness.music_hint", {"workout_type": "other"}),
]


@pytest.mark.parametrize(("text", "lang", "intent", "slots"), CASES)
def test_intents_three_languages(
    intents: IntentRegistry, text: str, lang: str, intent: str, slots: dict[str, Any]
) -> None:
    assert route(intents, text, lang) == (intent, slots)


def test_unrelated_text_matches_nothing_and_each_sentence_has_one_owner(intents: IntentRegistry) -> None:
    for text in ("what is the weather", "mujhe paise bhejo", "मौसम कैसा है", "play some music"):
        assert route(intents, text, "en") is None, text
    for text, *_ in CASES:
        owners = [
            s.name for s in intents.all() if s.extract(text, IntentContext(lang="en", now=NOW)) is not None
        ]
        assert len(owners) == 1, (text, owners)
    assert classify("steps trend") == "trend"


def test_keywords_cover_three_languages_and_tools_exist(
    intents: IntentRegistry, registry_tools: set[str]
) -> None:
    for spec in intents.all():
        assert all(spec.keywords.get(lang) for lang in ("en", "hi", "hinglish")), spec.name
        assert spec.tool in registry_tools and spec.examples


@pytest.fixture
def registry_tools(registry: PluginRegistry) -> set[str]:
    return {t.name for t in registry.tools}


def test_the_plugin_registers_the_intents(registry: PluginRegistry) -> None:
    assert len([s for s in registry.intents.all() if s.name.startswith("fitness.")]) == 9


# ---------------------------------------------------------------- routes


async def test_routes_require_a_device_and_the_health_grant(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    for path in ("/v1/fitness/summary", "/v1/fitness/weekly", "/v1/fitness/records", "/v1/fitness/freshness"):
        assert (await client.get(path)).status_code == 401
    await registry.service("permissions").set("health.read", False)
    denied = await client.get("/v1/fitness/summary", headers=paired_device.headers)
    assert denied.status_code == 403 and denied.json()["code"] == "permission_not_granted:health.read"


async def test_routes_return_the_same_results_as_the_tools(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    h = paired_device.headers
    assert (
        await client.post(
            "/v1/fitness/sync",
            json=payload(series(35, steps=lambda i: 6000 + 100 * i, exercise_minutes=30)),
            headers=h,
        )
    ).status_code == 200
    summary = (await client.get("/v1/fitness/summary", headers=h)).json()
    assert summary["steps"] == 9400 and summary["date"] == "2026-11-13" and summary["available"]
    assert summary["freshness"]["last_synced_at"] and summary["data_source"].startswith("Apple Health")
    assert (await client.get("/v1/fitness/summary", params={"date": "2026-11-12"}, headers=h)).json()[
        "steps"
    ] == 9300
    assert (await client.get("/v1/fitness/weekly", headers=h)).json()["metrics"]
    trend = (await client.get("/v1/fitness/trends", params={"metric": "steps", "days": 28}, headers=h)).json()
    assert trend["direction"] == "up"
    assert (await client.get("/v1/fitness/trends", params={"metric": "mood"}, headers=h)).status_code == 400
    assert (await client.get("/v1/fitness/consistency", headers=h)).json()["available"]
    assert (await client.get("/v1/fitness/running", headers=h)).json()["reason"] == "no_running_data"
    plan = (
        await client.post(
            "/v1/fitness/running-plan", json={"goal": "10k", "current_weekly_km": 15}, headers=h
        )
    ).json()
    assert plan["plan"]["start_basis"] == "user_provided" and len(plan["plan"]["weeks"]) == 10
    routine = (await client.post("/v1/fitness/routine", json={"days_per_week": 3}, headers=h)).json()
    assert len(routine["routine"]["days"]) == 3
    hint = (await client.get("/v1/fitness/music-hint", params={"workout_type": "yoga"}, headers=h)).json()
    assert hint["hint"]["energy"] == "low"
    fresh = (await client.get("/v1/fitness/freshness", headers=h)).json()
    assert fresh["stale"] is False and fresh["latest_data_date"] == "2026-11-13"
    caps = {c.id: c.status.value for c in registry.capabilities.all(domain="fitness")}
    assert caps["fitness.apple_health_sync"] == "working_local"


async def test_strava_routes_without_credentials(
    client: httpx.AsyncClient, paired_device: PairedDevice
) -> None:
    h = paired_device.headers
    status = (await client.get("/v1/fitness/strava/status", headers=h)).json()
    assert status == {"configured": False, "connected": False, "external_model_allowed": False}
    refused = await client.get(
        "/v1/fitness/strava/authorize-url", params={"redirect_uri": "zoro://strava"}, headers=h
    )
    assert refused.status_code == 503 and refused.json()["code"] == "strava_not_configured"
    bad_state = await client.post(
        "/v1/fitness/strava/callback", json={"code": "x", "state": "nope"}, headers=h
    )
    assert bad_state.status_code == 400 and bad_state.json()["code"] == "strava_state_invalid"
    assert (await client.post("/v1/fitness/strava/sync", headers=h)).status_code == 503


async def test_seed_helper_and_executor_agree_with_routes(registry: PluginRegistry) -> None:
    await seed(registry)
    assert (await registry.service("fitness_store").sync_state()).latest_day is not None
