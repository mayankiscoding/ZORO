from __future__ import annotations

from datetime import date

import httpx

from app.fitness.schemas import SyncIn
from app.fitness.store import FitnessStore
from app.plugins import PluginRegistry
from tests.conftest import PairedDevice
from tests.fitness.data import TODAY, day, payload, run


async def _post(client: httpx.AsyncClient, device: PairedDevice, body: dict) -> httpx.Response:
    return await client.post("/v1/fitness/sync", json=body, headers=device.headers)


async def test_sync_requires_a_signed_in_device(client: httpx.AsyncClient) -> None:
    assert (await client.post("/v1/fitness/sync", json=payload([]))).status_code == 401


async def test_sync_upserts_by_date_and_by_workout_id(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    store: FitnessStore = registry.service("fitness_store")
    first = await _post(
        client,
        paired_device,
        payload(
            [day(TODAY, steps=8421, resting_heart_rate_bpm=58, sleep_minutes=402)],
            [run("hk-1", TODAY, 5.0, 384.5)],
        ),
    )
    assert first.status_code == 200, first.text
    assert first.json()["days_created"] == 1 and first.json()["workouts_created"] == 1

    again = await _post(
        client,
        paired_device,
        payload(
            [day(TODAY, steps=9000, resting_heart_rate_bpm=57, sleep_minutes=402)],
            [run("hk-1", TODAY, 5.2, 380.0), run("hk-2", TODAY, 3.0, 400.0, hour=18)],
            generated="2026-11-13T13:00:00+05:30",
        ),
    )
    body = again.json()
    assert (body["days_created"], body["days_updated"]) == (0, 1)
    assert (body["workouts_created"], body["workouts_updated"]) == (1, 1)

    days = await store.days(TODAY, TODAY)
    assert len(days) == 1 and days[0].steps == 9000 and days[0].resting_heart_rate_bpm == 57
    assert days[0].sources == ("Apple Watch", "iPhone")
    workouts = await store.workouts(TODAY, TODAY)
    assert {w.id: w.distance_m for w in workouts} == {"hk-1": 5200.0, "hk-2": 3000.0}
    assert (await store.sync_state()).latest_day == TODAY


async def test_nulls_are_preserved_and_never_estimated(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    store: FitnessStore = registry.service("fitness_store")
    await _post(
        client, paired_device, payload([day(TODAY, steps=5000, sleep_minutes=400, body_mass_kg=70.5)])
    )
    # The owner withdrew sleep and weight access: the next sync carries nulls and they stay null.
    await _post(
        client,
        paired_device,
        payload(
            [day(TODAY, steps=6000, sleep_minutes=None, body_mass_kg=None)],
            generated="2026-11-13T13:00:00+05:30",
        ),
    )
    (row,) = await store.days(TODAY, TODAY)
    assert row.steps == 6000 and row.sleep_minutes is None and row.body_mass_kg is None
    assert (
        row.exercise_minutes is None and row.resting_heart_rate_bpm is None
    )  # absent fields are null, not 0

    only_nulls = await _post(client, paired_device, payload([{"date": "2026-11-12"}]))
    assert only_nulls.status_code == 200
    (empty,) = await store.days(date(2026, 11, 12), date(2026, 11, 12))
    assert all(
        getattr(empty, f) is None for f in ("steps", "sleep_minutes", "avg_heart_rate_bpm", "body_mass_kg")
    )


async def test_an_older_payload_never_overwrites_newer_data(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    store: FitnessStore = registry.service("fitness_store")
    await _post(
        client,
        paired_device,
        payload([day(TODAY, steps=9000)], [run("hk-1", TODAY, 5.0, 380)], "2026-11-13T13:00:00+05:30"),
    )
    stale = await _post(
        client,
        paired_device,
        payload([day(TODAY, steps=100)], [run("hk-1", TODAY, 1.0, 380)], "2026-11-13T08:00:00+05:30"),
    )
    body = stale.json()
    assert body["days_skipped_older"] == 1 and body["workouts_skipped_older"] == 1
    assert (await store.days(TODAY, TODAY))[0].steps == 9000
    assert (await store.workouts(TODAY, TODAY))[0].distance_m == 5000.0


async def test_repeated_dates_in_one_payload_keep_the_last(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    await _post(client, paired_device, payload([day(TODAY, steps=1), day(TODAY, steps=2)]))
    assert (await registry.service("fitness_store").days(TODAY, TODAY))[0].steps == 2


async def test_malformed_payloads_are_refused(client: httpx.AsyncClient, paired_device: PairedDevice) -> None:
    for bad in (
        {"days": []},  # no generated_at
        payload([{"date": "2026-11-13", "steps": -5}]),
        payload([{"date": "2026-11-13", "resting_heart_rate_bpm": 900}]),
        payload([{"date": "not-a-date"}]),
        {"generated_at": "2026-11-13T12:00:00", "days": []},  # naive time
        payload([], [{"id": "", "start_at": "2026-11-13T06:00:00+05:30"}]),
    ):
        assert (await _post(client, paired_device, bad)).status_code == 422, bad


async def test_unknown_workout_type_becomes_other_and_local_date_follows_the_device_clock(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    w = run("hk-9", TODAY, 2.0, 400.0, hour=0)  # 00:10 at +05:30 is the previous day in UTC
    w["type"] = "pickleball"
    assert (await _post(client, paired_device, payload([], [w]))).status_code == 200
    (stored,) = await registry.service("fitness_store").workouts(None, None)
    assert stored.type == "other" and stored.local_date == TODAY


def test_sync_model_accepts_the_contract_example() -> None:
    SyncIn.model_validate(
        {
            "generated_at": "2026-11-13T06:30:00+05:30",
            "days": [
                {
                    "date": "2026-11-12",
                    "steps": 8421,
                    "walking_running_distance_m": 6120.5,
                    "cycling_distance_m": 0,
                    "active_energy_kcal": 412.0,
                    "exercise_minutes": 38,
                    "resting_heart_rate_bpm": 58,
                    "avg_heart_rate_bpm": 74,
                    "sleep_minutes": 402,
                    "body_mass_kg": None,
                    "sources": ["Apple Watch", "iPhone"],
                }
            ],
            "workouts": [
                {
                    "id": "hk-uuid",
                    "type": "running",
                    "start_at": "2026-11-12T06:10:00+05:30",
                    "end_at": "2026-11-12T06:42:10+05:30",
                    "duration_s": 1930,
                    "distance_m": 5020.0,
                    "active_energy_kcal": 331.0,
                    "avg_heart_rate_bpm": 152,
                    "avg_pace_s_per_km": 384.5,
                    "source": "Apple Watch",
                }
            ],
        }
    )
