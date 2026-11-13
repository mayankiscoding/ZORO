"""Writes the JSON fixtures the ZoroLife tests decode, built from the backend's real Pydantic models and
pure functions (fitness, vision, music), so the Swift DTOs cannot drift from the server.

Run from the backend directory:
    cd backend && PYTHONPATH=. uv run --no-sync python ../ios/Packages/ZoroLife/scripts/generate_fixtures.py

All values are test data and live only under ZoroLife/Tests/**.
"""

from __future__ import annotations

import json
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

from pydantic import BaseModel

from app.fitness.cards import card as fitness_card
from app.fitness.observations import TEMPLATES, Observation, render_observation
from app.fitness.plans import build_running_plan
from app.fitness.results import (
    Consistency,
    DailySummary,
    MetricComparison,
    PersonalRecord,
    PersonalRecords,
    RunningProgress,
    TrendResult,
    WeeklyComparison,
    WeeklyKm,
    WeekSessions,
    WorkoutBrief,
)
from app.fitness.schemas import DayIn, Freshness, SyncIn, SyncOut, WorkoutIn
from app.fitness.service import RunningPlanOut
from app.music.schemas import (
    ConnectOut,
    MusicResult,
    MusicSession,
    MusicStatus,
    MusicTrack,
    SearchOut,
    SessionDevice,
    SpotifyStatus,
)
from app.music.speech import music_card
from app.vision.parser import parse_photo_query
from app.vision.schemas import ParsedQuery, PhotoHitOut, PhotoQuery, ShowResultsOut
from app.vision.service import build_plan
from app.vision.summaries import parse_card, query_chips, show_card

ROOT = Path(__file__).resolve().parents[1] / "Tests"
NOW = datetime(2026, 11, 13, 12, 0, tzinfo=UTC)
TODAY = date(2026, 11, 13)


def dump(target: str, name: str, value: Any) -> None:
    path = ROOT / f"{target}Tests" / "Fixtures" / f"{name}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    data = value.model_dump(mode="json") if isinstance(value, BaseModel) else value
    path.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


# ---------------------------------------------------------------- fitness

fresh = Freshness(
    last_synced_at=NOW - timedelta(hours=2),
    latest_data_date=TODAY,
    age_value=2,
    age_unit="hours",
    stale=False,
)
stale = Freshness(
    last_synced_at=NOW - timedelta(days=4),
    latest_data_date=TODAY - timedelta(days=4),
    age_value=4,
    age_unit="days",
    stale=True,
)
obs = [
    Observation(code="rhr_above_baseline", values={"days": 3, "delta": 6}),
    Observation(code="load_up", values={"ratio_pct": 140}),
]
common: dict[str, Any] = {"freshness": fresh, "devices": ["Apple Watch", "iPhone"]}

daily = DailySummary(
    date=TODAY,
    steps=8421,
    distance_km=6.1,
    cycling_km=None,
    active_energy_kcal=412,
    exercise_minutes=38,
    resting_heart_rate_bpm=58,
    avg_heart_rate_bpm=74,
    sleep_hours=6.7,
    body_mass_kg=None,
    workouts=[
        WorkoutBrief(
            id="w1",
            type="running",
            start_at="2026-11-13T06:10:00+05:30",
            duration_min=32.2,
            distance_km=5.02,
            pace_text="6:24",
            avg_heart_rate_bpm=152,
        )
    ],
    observations=obs,
    **common,
)
dump("FitnessFeature", "summary", daily)
dump("FitnessFeature", "summary_unavailable", DailySummary(date=TODAY, available=False, reason="never_synced"))
dump("FitnessFeature", "summary_stale", DailySummary(date=TODAY, steps=5000, freshness=stale))

weekly = WeeklyComparison(
    current_start=TODAY - timedelta(days=6),
    current_end=TODAY,
    previous_start=TODAY - timedelta(days=13),
    previous_end=TODAY - timedelta(days=7),
    metrics=[
        MetricComparison(
            metric="steps", unit="steps", current_avg=8421.5, previous_avg=7010.25, current_total=58950.0,
            previous_total=49072.0, change_pct=20.1, days_current=7, days_previous=7, enough_data=True,
        ),
        MetricComparison(
            metric="sleep_hours", unit="hours", current_avg=6.7, previous_avg=7.1, change_pct=-5.6,
            days_current=7, days_previous=7, enough_data=True,
        ),
        MetricComparison(metric="body_mass_kg", unit="kg", days_current=1, days_previous=0, enough_data=False),
    ],
    workouts_current=4,
    workouts_previous=3,
    **common,
)
dump("FitnessFeature", "weekly", weekly)
dump(
    "FitnessFeature",
    "trend",
    TrendResult(
        metric="steps", unit="steps", window_start=TODAY - timedelta(days=27), window_end=TODAY,
        points_used=26, slope_per_week=312.5, mean=7890.4, direction="up", **common,
    ),
)
dump(
    "FitnessFeature",
    "trend_insufficient",
    TrendResult(metric="body_mass_kg", unit="kg", available=False, reason="not_enough_data", points_used=2),
)
running = RunningProgress(
    window_start=TODAY - timedelta(days=89), window_end=TODAY, runs=14, total_km=71.3,
    avg_pace_s_per_km=392.4, avg_pace_text="6:32", recent_pace_text="6:18",
    pace_change_s_per_km_per_week=-3.2, direction="faster",
    weekly=[WeeklyKm(week_start=TODAY - timedelta(days=7 * (3 - i)), km=km, runs=r) for i, (km, r) in enumerate([(12.0, 2), (15.5, 3), (0.0, 0), (18.2, 3)])],
    **common,
)
dump("FitnessFeature", "running", running)
dump("FitnessFeature", "running_none", RunningProgress(available=False, reason="no_running_data"))
records = PersonalRecords(
    records=[
        PersonalRecord(kind="longest_run", value=10.4, unit="km", display="10.4", on=TODAY - timedelta(days=9), workout_id="w9", source="Apple Watch"),
        PersonalRecord(kind="fastest_pace_run", value=312.0, unit="min per km", display="5:12", on=TODAY - timedelta(days=20)),
        PersonalRecord(kind="most_steps_day", value=18234.0, unit="steps", display="18234", on=TODAY - timedelta(days=30)),
    ],
    **common,
)
dump("FitnessFeature", "records", records)
consistency = Consistency(
    window_start=TODAY - timedelta(days=55), window_end=TODAY, days_with_data=50, active_days=31,
    current_streak_days=3, longest_streak_days=6, avg_sessions_per_week=3.4, target_sessions_per_week=3,
    weeks_meeting_target=5,
    weeks=[WeekSessions(week_start=TODAY - timedelta(days=7 * (7 - i)), sessions=s, active_days=min(s, 4)) for i, s in enumerate([2, 3, 4, 3, 3, 4, 2, 3])],
    **common,
)
dump("FitnessFeature", "consistency", consistency)
dump("FitnessFeature", "freshness", fresh)
dump("FitnessFeature", "freshness_never", Freshness())

plan = build_running_plan("first_5k", weeks=8, days_per_week=3, current_weekly_km=10.0, recent_pace_text="6:32")
dump("FitnessFeature", "plan", RunningPlanOut(plan=plan, **common))
dump("FitnessFeature", "plan_10k_assumed", RunningPlanOut(plan=build_running_plan("10k", days_per_week=4), **common))

dump("FitnessFeature", "card_daily", fitness_card(daily, "Today"))
dump("FitnessFeature", "card_weekly", fitness_card(weekly, "This week"))
dump("FitnessFeature", "card_records", fitness_card(records, "Personal records"))
dump("FitnessFeature", "card_running", fitness_card(running, "Running"))
dump("FitnessFeature", "card_plan", fitness_card(RunningPlanOut(plan=plan, **common), "Running plan"))
dump("FitnessFeature", "card_stale", fitness_card(DailySummary(date=TODAY, steps=5000, freshness=stale), "Today"))

dump(
    "FitnessFeature",
    "sync_out",
    SyncOut(
        received_at=NOW, generated_at=NOW, days_created=3, days_updated=11, days_skipped_older=0,
        workouts_created=2, workouts_updated=0, workouts_skipped_older=0,
    ),
)
dump(
    "FitnessFeature",
    "sync_in_fields",
    {
        "SyncIn": sorted(SyncIn.model_fields),
        "DayIn": sorted(DayIn.model_fields),
        "WorkoutIn": sorted(WorkoutIn.model_fields),
    },
)
sentences: dict[str, Any] = {}
samples = {
    "rhr_above_baseline": {"days": 3, "delta": 6},
    "rhr_below_baseline": {"days": 3, "delta": 4},
    "short_sleep_run": {"hours": 6, "nights": 3},
    "load_up": {"ratio_pct": 140},
}
for code in TEMPLATES:
    values = samples[code]
    sentences[code] = {"values": values, "en": render_observation(Observation(code=code, values=values), "en")}
dump("FitnessFeature", "observation_sentences", sentences)

# ---------------------------------------------------------------- photos

parsed = parse_photo_query("photo from yesterday with my blue cap", NOW, "Asia/Kolkata")
parsed_query = ParsedQuery(
    query=parsed.query, assumptions=list(parsed.assumptions), matched=parsed.matched, plan=build_plan(parsed.query)
)
dump("PhotosFeature", "parsed_query", parsed_query)
cases = [
    "photo from yesterday with my blue cap",
    "screenshots from last week that say \"boarding pass\"",
    "red car",
    "photos",
]
chip_cases = []
for text in cases:
    q = parse_photo_query(text, NOW, "Asia/Kolkata").query
    chip_cases.append({"text": text, "query": q.model_dump(mode="json"), "chips": query_chips(q)})
dump("PhotosFeature", "chip_cases", chip_cases)

query = parsed.query
hits = [
    PhotoHitOut(asset_id="B84E8479-475C-4727-A4A4-B77AA9980897/L0/001", captured_at=NOW - timedelta(days=1), score=0.91, labels=["cap", "hat"]),
    PhotoHitOut(asset_id="9F1C2A10-0000-4000-8000-000000000002/L0/001", captured_at=None, score=0.5, labels=[]),
]
dump(
    "PhotosFeature",
    "card_found",
    show_card(ShowResultsOut(query=query, hits=hits, asset_ids=[h.asset_id for h in hits], indexed_count=1204, limited_library=True)),
)
dump("PhotosFeature", "card_empty", show_card(ShowResultsOut(query=PhotoQuery(text="purple elephant", labels=["elephant"]), hits=[], asset_ids=[], indexed_count=1204)))
dump("PhotosFeature", "card_searching", parse_card(parsed_query))

# ---------------------------------------------------------------- music

dump("MusicFeature", "status_connected", MusicStatus(spotify=SpotifyStatus(state="connected", detail="Signed in. Spotify checks Premium and the app's allowed-user list when playback is used."), apple_music="Played by the device through device.music.control (needs a device online).", provider_in_use="spotify", recommendations="Unavailable: Spotify removed recommendations for new apps; similar songs use search."))
dump("MusicFeature", "status_not_configured", MusicStatus(spotify=SpotifyStatus(state="not_configured", detail="Set SPOTIFY_CLIENT_ID on the server."), apple_music="Played by the device through device.music.control (needs a device online).", provider_in_use="apple_music", recommendations="Unavailable: Spotify removed recommendations for new apps; similar songs use search."))
dump("MusicFeature", "status_reauth", MusicStatus(spotify=SpotifyStatus(state="needs_reauthorization", detail="Spotify rejected the stored sign-in. Connect again."), apple_music="Played by the device through device.music.control (needs a device online).", provider_in_use="spotify", recommendations="Unavailable: Spotify removed recommendations for new apps; similar songs use search."))
track = MusicTrack(uri="spotify:track:4uLU6hMCjMI75M1A2tKUQC", title="Example title", artists=["Example artist"], album="Example album", played_at=NOW - timedelta(minutes=5))
dump("MusicFeature", "session", MusicSession(provider="spotify", active_device=SessionDevice(id="abc123", name="Mac", type="Computer"), last_query="focus music", last_track=track, updated_at=NOW, updated_by="dev-1"))
dump("MusicFeature", "session_empty", MusicSession())
dump("MusicFeature", "connect", ConnectOut(authorize_url="https://accounts.spotify.com/authorize?client_id=x&state=s", state="s", expires_at=NOW + timedelta(minutes=10), redirect_uri="https://zoro.example/v1/music/callback"))
dump("MusicFeature", "card_songs", music_card(SearchOut(status="ok", provider="spotify", query="focus", tracks=[track])))
dump("MusicFeature", "card_now_playing", music_card(MusicResult(status="ok", provider="spotify", track=track)))
print("fixtures written under", ROOT)
