"""Strava adapter on httpx.MockTransport: OAuth, paging, expired token, 429, and the AI-use flag."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qs, urlparse

import httpx
import pytest

from app.core.clock import FixedClock
from app.core.errors import Unavailable
from app.core.types import CapabilityStatus
from app.fitness.store import FitnessStore
from app.fitness.strava import (
    MODEL_POLICY,
    StravaAdapter,
    StravaNotConfigured,
    StravaRateLimited,
    StravaReauthRequired,
    map_activity,
    seconds_until_reset,
)
from app.plugins import PluginRegistry
from tests.fitness.conftest import NOW, make_ctx

ENV = {"STRAVA_CLIENT_ID": "cid", "STRAVA_CLIENT_SECRET": "csecret"}


def activity(n: int, kind: str = "Run", *, km: float = 5.0, moving: int = 1800) -> dict[str, Any]:
    return {
        "id": 1000 + n,
        "type": kind,
        "sport_type": kind,
        "distance": km * 1000,
        "moving_time": moving,
        "elapsed_time": moving + 60,
        "start_date": f"2026-11-{10 + n % 3:02d}T00:40:00Z",
        "start_date_local": f"2026-11-{10 + n % 3:02d}T06:10:00Z",
        "average_heartrate": 150.0,
    }


class Fake:
    """Records requests and answers from scripted handlers."""

    def __init__(self) -> None:
        self.calls: list[httpx.Request] = []
        self.api: list[httpx.Response] = []
        self.token: list[httpx.Response] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        queue = self.token if request.url.path.endswith("/oauth/token") else self.api
        assert queue, f"unexpected request {request.method} {request.url}"
        return queue.pop(0)


def token_response(access: str = "acc-2", refresh: str = "ref-2", expires_at: int = 0) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "access_token": access,
            "refresh_token": refresh,
            "expires_at": expires_at or int(NOW.timestamp()) + 21600,
        },
    )


@pytest.fixture
def fake() -> Fake:
    return Fake()


@pytest.fixture
def adapter(registry: PluginRegistry, clock: FixedClock, fake: Fake) -> StravaAdapter:
    return StravaAdapter(
        env=ENV,
        secrets=registry.service("secrets"),
        store=registry.service("fitness_store"),
        clock=clock,
        transport=httpx.MockTransport(fake),
    )


async def connect(adapter: StravaAdapter, fake: Fake, *, expires_in: int = 3600) -> None:
    fake.token.append(token_response("acc-1", "ref-1", int(NOW.timestamp()) + expires_in))
    await adapter.exchange_code("the-code")
    fake.calls.clear()


# ---------------------------------------------------------------- configuration and OAuth


async def test_missing_credentials_are_a_capability_status_not_an_error(
    registry: PluginRegistry, clock: FixedClock
) -> None:
    bare = StravaAdapter(
        env={}, secrets=registry.service("secrets"), store=registry.service("fitness_store"), clock=clock
    )
    assert not bare.configured and bare.capability().status is CapabilityStatus.REQUIRES_CREDENTIALS
    with pytest.raises(StravaNotConfigured):
        bare.authorize_url("zoro://strava", "s")
    with pytest.raises(StravaNotConfigured):
        await bare.exchange_code("c")
    await bare.refresh_state()
    assert not bare.connected


async def test_the_plugin_publishes_honest_capabilities(registry: PluginRegistry) -> None:
    caps = {c.id: c for c in registry.capabilities.all(domain="fitness")}
    assert (
        caps["fitness.fitbit"].status is CapabilityStatus.UNAVAILABLE
        and "2026-11-02" in caps["fitness.fitbit"].note
    )
    assert caps["fitness.garmin"].status is CapabilityStatus.REQUIRES_PARTNERSHIP
    assert caps["fitness.apple_health_sync"].status is CapabilityStatus.MANUAL_USER_STEP  # nothing synced yet
    assert caps["fitness.strava"].status in (
        CapabilityStatus.REQUIRES_CREDENTIALS,
        CapabilityStatus.MANUAL_USER_STEP,
    )


async def test_connect_flow_and_capability_status(
    adapter: StravaAdapter, fake: Fake, registry: PluginRegistry
) -> None:
    assert adapter.capability().status is CapabilityStatus.MANUAL_USER_STEP
    url = urlparse(adapter.authorize_url("zoro://strava", "state-1"))
    query = parse_qs(url.query)
    assert url.netloc == "www.strava.com" and query["client_id"] == ["cid"] and query["state"] == ["state-1"]
    assert "activity:read_all" in query["scope"][0] and "client_secret" not in url.query
    await connect(adapter, fake)
    assert adapter.connected and adapter.capability().status is CapabilityStatus.WORKING_INTEGRATION
    assert await registry.service("secrets").get(
        "strava", allow_expired=True
    )  # stored sealed, readable only via SecretStore


async def test_bad_code_needs_reauthorisation(adapter: StravaAdapter, fake: Fake) -> None:
    fake.token.append(httpx.Response(400, json={"message": "Bad Request"}))
    with pytest.raises(StravaReauthRequired):
        await adapter.exchange_code("expired-code")
    assert not adapter.connected


# ---------------------------------------------------------------- sync, paging, mapping


async def test_sync_stores_restricted_workouts_and_asks_only_for_newer_ones(
    adapter: StravaAdapter, fake: Fake, registry: PluginRegistry
) -> None:
    await connect(adapter, fake)
    fake.api.append(
        httpx.Response(
            200,
            json=[activity(1), activity(2, "Ride", km=20, moving=3600), {"id": "bad"}],
            headers={"X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "3,30"},
        )
    )
    result = await adapter.sync()
    assert (result.created, result.updated, result.pages) == (2, 0, 1)
    assert result.external_model_allowed is False and MODEL_POLICY["external_models"] is False
    request = fake.calls[0]
    assert request.headers["authorization"] == "Bearer acc-1" and request.url.params["per_page"] == "100"
    assert "after" not in request.url.params

    store: FitnessStore = registry.service("fitness_store")
    stored = await store.workouts(None, None, include_strava=True)
    assert {w.id for w in stored} == {"strava:1001", "strava:1002"} and all(
        w.origin == "strava" for w in stored
    )
    run = next(w for w in stored if w.type == "running")
    assert run.pace_s_per_km == pytest.approx(360.0) and run.source == "Strava"
    assert await store.workouts(None, None) == []  # kept out of every default answer

    fake.api.append(httpx.Response(200, json=[activity(1)]))  # an update of a known activity
    again = await adapter.sync()
    assert (again.created, again.updated) == (0, 1)
    assert fake.calls[-1].url.params["after"] == str(int(max(w.start_at for w in stored).timestamp()))


async def test_paging_stops_before_the_rate_limit(adapter: StravaAdapter, fake: Fake) -> None:
    await connect(adapter, fake)
    page = [activity(i) for i in range(100)]
    fake.api.append(
        httpx.Response(
            200, json=page, headers={"X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "185,900"}
        )
    )
    result = await adapter.sync()
    assert result.pages == 1 and result.stopped_for_rate_limit and result.usage_15min == 185
    assert len(fake.calls) == 1  # no second page requested
    assert adapter.last_usage == (185, 900)


async def test_full_pages_are_followed_until_a_short_one(adapter: StravaAdapter, fake: Fake) -> None:
    await connect(adapter, fake)
    fake.api += [
        httpx.Response(200, json=[activity(i) for i in range(100)]),
        httpx.Response(200, json=[activity(i) for i in range(100, 130)]),
    ]
    result = await adapter.sync()
    assert result.pages == 2 and fake.calls[1].url.params["page"] == "2"


def test_activity_mapping() -> None:
    walk = map_activity({**activity(1, "Hike"), "calories": 300})
    assert walk and walk.type == "walking" and walk.active_energy_kcal == 300
    assert map_activity({**activity(2, "Kitesurf")}).type == "other"  # type: ignore[union-attr]
    assert map_activity({"id": 5}) is None and map_activity({**activity(3), "start_date": "garbage"}) is None
    ride = map_activity(activity(4, "Ride"))
    assert ride and ride.avg_pace_s_per_km is None  # no pace for rides


# ---------------------------------------------------------------- tokens


async def test_an_expired_token_is_refreshed_before_the_call(adapter: StravaAdapter, fake: Fake) -> None:
    await connect(adapter, fake, expires_in=-60)
    fake.token.append(token_response("acc-new", "ref-new"))
    fake.api.append(httpx.Response(200, json=[]))
    await adapter.sync()
    refresh, api = fake.calls
    body = parse_qs(refresh.content.decode())
    assert body["grant_type"] == ["refresh_token"] and body["refresh_token"] == ["ref-1"]
    assert api.headers["authorization"] == "Bearer acc-new"
    fake.token.append(
        token_response("acc-3", "ref-3")
    )  # the new token is stored: no second refresh needed now
    fake.api.append(httpx.Response(200, json=[]))
    await adapter.sync()
    assert fake.calls[-1].headers["authorization"] == "Bearer acc-new"


async def test_a_401_triggers_one_refresh_and_retry(adapter: StravaAdapter, fake: Fake) -> None:
    await connect(adapter, fake)
    fake.api += [httpx.Response(401, json={}), httpx.Response(200, json=[activity(1)])]
    fake.token.append(token_response("acc-fresh", "ref-fresh"))
    assert (await adapter.sync()).created == 1
    assert [c.headers.get("authorization") for c in fake.calls if "athlete" in str(c.url)] == [
        "Bearer acc-1",
        "Bearer acc-fresh",
    ]


async def test_repeated_401_and_refused_refresh_need_reauthorisation(
    adapter: StravaAdapter, fake: Fake
) -> None:
    await connect(adapter, fake)
    fake.api += [httpx.Response(401, json={}), httpx.Response(401, json={})]
    fake.token.append(token_response())
    with pytest.raises(StravaReauthRequired):
        await adapter.sync()
    await connect(adapter, fake, expires_in=-10)
    fake.token.append(httpx.Response(400, json={"message": "invalid refresh token"}))
    with pytest.raises(StravaReauthRequired):
        await adapter.sync()


async def test_syncing_without_connecting_asks_to_authorise(adapter: StravaAdapter) -> None:
    with pytest.raises(StravaReauthRequired):
        await adapter.sync()


# ---------------------------------------------------------------- rate limits and outages


async def test_429_reports_when_the_window_resets(adapter: StravaAdapter, fake: Fake) -> None:
    await connect(adapter, fake)
    fake.api.append(
        httpx.Response(
            429, json={}, headers={"X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "201,900"}
        )
    )
    with pytest.raises(StravaRateLimited) as short:
        await adapter.sync()
    assert short.value.detail == {"retry_after_s": 900, "window": "15_minutes"}  # 06:30:00 -> 06:45:00
    assert short.value.status == 429 and short.value.retryable
    assert len(fake.calls) == 1  # no retry loop against a limited API

    fake.api.append(
        httpx.Response(
            429, json={}, headers={"X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "40,2001"}
        )
    )
    with pytest.raises(StravaRateLimited) as daily:
        await adapter.sync()
    assert daily.value.detail == {"retry_after_s": 17 * 3600 + 30 * 60, "window": "daily"}


def test_reset_windows() -> None:
    assert seconds_until_reset(datetime(2026, 11, 13, 6, 14, 59, tzinfo=UTC), daily=False) == 1
    assert seconds_until_reset(datetime(2026, 11, 13, 6, 45, 0, tzinfo=UTC), daily=False) == 900
    assert seconds_until_reset(datetime(2026, 11, 13, 23, 59, 0, tzinfo=UTC), daily=False) == 60
    assert seconds_until_reset(datetime(2026, 11, 13, 23, 59, 0, tzinfo=UTC), daily=True) == 60


async def test_outage_and_server_errors_are_typed_unavailable(adapter: StravaAdapter, fake: Fake) -> None:
    await connect(adapter, fake)
    fake.api.append(httpx.Response(503, text="down"))
    with pytest.raises(Unavailable):
        await adapter.sync()

    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route")

    offline = StravaAdapter(
        env=ENV,
        secrets=adapter._secrets,
        store=adapter._store,
        clock=adapter._clock,
        transport=httpx.MockTransport(boom),
    )
    with pytest.raises(Unavailable):
        await offline.sync()


# ---------------------------------------------------------------- never sent to an external model


async def test_strava_data_is_flagged_and_excluded_unless_asked_for(
    adapter: StravaAdapter, fake: Fake, registry: PluginRegistry
) -> None:
    from tests.fitness.data import TODAY

    await connect(adapter, fake)
    fake.api.append(
        httpx.Response(
            200,
            json=[
                {
                    **activity(1),
                    "start_date": "2026-11-12T00:40:00Z",
                    "start_date_local": "2026-11-12T06:10:00Z",
                }
            ],
        )
    )
    await adapter.sync()
    executor = registry.service("tool_executor")
    await registry.service("permissions").set("health.read", True)

    async def call(args: dict[str, Any], cid: str) -> Any:
        outcome = await executor.execute(make_ctx(registry), "fitness.running_progress", args, call_id=cid)
        return outcome.result  # type: ignore[union-attr]

    default = await call({}, "c1")
    assert default.runs == 0 and default.external_model_allowed is True  # Strava not used: nothing restricted
    with_strava = await call({"include_strava": True}, "c2")
    assert with_strava.runs == 1 and with_strava.external_model_allowed is False
    assert "Strava" in with_strava.data_source
    assert TODAY.year == 2026
