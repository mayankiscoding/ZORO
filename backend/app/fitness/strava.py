"""Strava adapter: the owner's own activities over OAuth 2.0, with rate-limit handling.

- Tokens are stored encrypted through `SecretStore` (provider "strava"); never logged.
- Only the owner's own activities are read (`/athlete/activities`); nothing is shared with anyone.
- Strava's agreement restricts how its data may be used, and AI use is unresolved (research
  2026-11-12): every stored Strava workout is flagged `ai_restricted`, never included in an answer
  unless the owner asks for it, and the answer then carries `external_model_allowed = False`.
- Rate limits (200 requests per 15 minutes, 2000 per day by default): a 429 raises `RateLimited`
  with the number of seconds until the window resets; usage headers are tracked and paging stops
  before the limit.
- A missing client id / secret is a capability status (`requires_credentials`), never a startup error.
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Any
from urllib.parse import urlencode

import httpx

from app.core.clock import Clock
from app.core.errors import RateLimited, Unavailable, ZoroError
from app.core.types import CapabilityStatus, IntegrationLevel
from app.fitness.records import WorkoutRec
from app.fitness.schemas import FModel
from app.fitness.store import FitnessStore
from app.schemas.security import Capability

PROVIDER = "strava"
API_BASE = "https://www.strava.com/api/v3"
AUTHORIZE_URL = "https://www.strava.com/oauth/authorize"
TOKEN_URL = "https://www.strava.com/oauth/token"  # noqa: S105 - a URL, not a credential
SCOPE = "read,activity:read_all"
MODEL_POLICY = {
    "external_models": False,
    "reason": "Strava API terms: the owner's data is for the owner only.",
}
REFRESH_MARGIN_S = 60
USAGE_STOP_RATIO = 0.9  # stop paging when 90% of a window is used
TIMEOUT = httpx.Timeout(10.0, connect=5.0)
MAX_PAGES = 5
PER_PAGE = 100

_TYPE_MAP = {
    "Run": "running",
    "TrailRun": "running",
    "VirtualRun": "running",
    "Walk": "walking",
    "Hike": "walking",
    "Ride": "cycling",
    "VirtualRide": "cycling",
    "EBikeRide": "cycling",
    "GravelRide": "cycling",
    "MountainBikeRide": "cycling",
    "WeightTraining": "strength",
    "Workout": "strength",
    "Crossfit": "strength",
    "Yoga": "yoga",
    "Swim": "swimming",
}


class StravaNotConfigured(ZoroError):
    code = "strava_not_configured"
    status = 503
    default_message = "Set STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET on the server to connect Strava."


class StravaReauthRequired(ZoroError):
    code = "strava_reauthorization_required"
    status = 409
    default_message = "Strava needs to be connected again. Authorise ZORO from the fitness settings."


class StravaRateLimited(RateLimited):
    code = "strava_rate_limited"
    default_message = "Strava's request limit is reached. ZORO will not retry until the window resets."


class StravaSyncResult(FModel):
    created: int = 0
    updated: int = 0
    pages: int = 0
    stopped_for_rate_limit: bool = False
    usage_15min: int | None = None
    usage_daily: int | None = None
    external_model_allowed: bool = False  # always: see MODEL_POLICY


@dataclass
class StravaTokens:
    access_token: str
    refresh_token: str
    expires_at: int  # epoch seconds

    def dumps(self) -> str:
        return json.dumps({"a": self.access_token, "r": self.refresh_token, "e": self.expires_at})

    @classmethod
    def loads(cls, raw: str) -> StravaTokens | None:
        try:
            data = json.loads(raw)
            return cls(str(data["a"]), str(data["r"]), int(data["e"]))
        except (ValueError, KeyError, TypeError):
            return None


def seconds_until_reset(now: datetime, *, daily: bool) -> int:
    """Strava's 15-minute windows end on :00, :15, :30, :45 (UTC); the daily window ends at midnight UTC."""
    now = now.astimezone(UTC)
    if daily:
        nxt = datetime.combine(now.date() + timedelta(days=1), datetime.min.time(), tzinfo=UTC)
    else:
        minute = (now.minute // 15 + 1) * 15
        nxt = now.replace(minute=0, second=0, microsecond=0) + timedelta(minutes=minute)
    return max(int((nxt - now).total_seconds()), 1)


def _pair(value: str | None) -> tuple[int, int] | None:
    try:
        a, b = (value or "").split(",")[:2]
        return int(a), int(b)
    except ValueError:
        return None


def map_activity(item: Mapping[str, Any]) -> WorkoutRec | None:
    """A Strava activity as a workout record; None when it lacks an id or a start time."""
    try:
        sid = int(item["id"])
        start = datetime.fromisoformat(str(item["start_date"]).replace("Z", "+00:00"))
        local_day = date.fromisoformat(str(item.get("start_date_local") or item["start_date"])[:10])
    except (KeyError, ValueError, TypeError):
        return None
    kind = _TYPE_MAP.get(str(item.get("sport_type") or item.get("type") or ""), "other")
    distance = float(item["distance"]) if isinstance(item.get("distance"), int | float) else None
    moving = float(item["moving_time"]) if isinstance(item.get("moving_time"), int | float) else None
    elapsed = float(item["elapsed_time"]) if isinstance(item.get("elapsed_time"), int | float) else None
    pace = (
        moving / (distance / 1000.0)
        if kind in ("running", "walking") and moving and distance and distance >= 100
        else None
    )
    hr = item.get("average_heartrate")
    kcal = item.get("calories")
    return WorkoutRec(
        id=f"strava:{sid}",
        type=kind,
        start_at=start,
        local_date=local_day,
        origin="strava",
        end_at=start + timedelta(seconds=elapsed) if elapsed else None,
        duration_s=moving,
        distance_m=distance,
        active_energy_kcal=float(kcal) if isinstance(kcal, int | float) else None,
        avg_heart_rate_bpm=float(hr) if isinstance(hr, int | float) else None,
        avg_pace_s_per_km=pace,
        source="Strava",
    )


class StravaAdapter:
    def __init__(
        self,
        *,
        env: Mapping[str, str],
        secrets: Any,
        store: FitnessStore,
        clock: Clock,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._client_id = env.get("STRAVA_CLIENT_ID", "")
        self._client_secret = env.get("STRAVA_CLIENT_SECRET", "")
        self._secrets = secrets
        self._store = store
        self._clock = clock
        self._transport = transport
        self.connected = False  # refreshed at startup and whenever tokens change
        self.last_usage: tuple[int, int] | None = None

    @property
    def configured(self) -> bool:
        return bool(self._client_id and self._client_secret)

    def capability(self) -> Capability:
        if not self.configured:
            status, note = (
                CapabilityStatus.REQUIRES_CREDENTIALS,
                "Set STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET.",
            )
        elif not self.connected:
            status, note = (
                CapabilityStatus.MANUAL_USER_STEP,
                "Authorise ZORO to read your own Strava activities.",
            )
        else:
            status, note = (
                CapabilityStatus.WORKING_INTEGRATION,
                "Own activities only; kept out of external model prompts.",
            )
        return Capability(
            id="fitness.strava",
            title="Strava activities",
            domain="fitness",
            status=status,
            integration_level=IntegrationLevel.OFFICIAL_API,
            requires=["STRAVA_CLIENT_ID", "STRAVA_CLIENT_SECRET"],
            note=note,
        )

    async def refresh_state(self) -> None:
        self.connected = self.configured and await self._load() is not None

    # ------------------------------------------------------------ OAuth

    def authorize_url(self, redirect_uri: str, state: str) -> str:
        if not self.configured:
            raise StravaNotConfigured()
        query = urlencode(
            {
                "client_id": self._client_id,
                "redirect_uri": redirect_uri,
                "response_type": "code",
                "approval_prompt": "auto",
                "scope": SCOPE,
                "state": state,
            }
        )
        return f"{AUTHORIZE_URL}?{query}"

    async def exchange_code(self, code: str) -> None:
        tokens = await self._token_request({"grant_type": "authorization_code", "code": code})
        await self._save(tokens)

    async def _token_request(self, data: dict[str, str]) -> StravaTokens:
        if not self.configured:
            raise StravaNotConfigured()
        body = {"client_id": self._client_id, "client_secret": self._client_secret, **data}
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT, transport=self._transport) as http:
                response = await http.post(TOKEN_URL, data=body)
        except httpx.HTTPError as exc:
            raise Unavailable("Strava could not be reached.") from exc
        if response.status_code == 429:
            raise self._limited(response)
        if response.status_code in (400, 401, 403):
            raise StravaReauthRequired()
        if response.status_code >= 400:
            raise Unavailable(f"Strava answered {response.status_code}.")
        payload = response.json()
        try:
            return StravaTokens(
                str(payload["access_token"]), str(payload["refresh_token"]), int(payload["expires_at"])
            )
        except (KeyError, ValueError, TypeError) as exc:
            raise Unavailable("Strava sent an unexpected token response.") from exc

    async def _load(self) -> StravaTokens | None:
        raw = await self._secrets.get(PROVIDER, allow_expired=True)
        return StravaTokens.loads(raw) if raw else None

    async def _save(self, tokens: StravaTokens) -> None:
        await self._secrets.put(PROVIDER, tokens.dumps())
        self.connected = True

    async def disconnect(self) -> None:
        await self._secrets.delete(PROVIDER)
        self.connected = False

    async def _access_token(self, *, force_refresh: bool = False) -> str:
        if not self.configured:
            raise StravaNotConfigured()
        tokens = await self._load()
        if tokens is None:
            self.connected = False
            raise StravaReauthRequired()
        if force_refresh or tokens.expires_at - REFRESH_MARGIN_S <= self._clock.now().timestamp():
            tokens = await self._token_request(
                {"grant_type": "refresh_token", "refresh_token": tokens.refresh_token}
            )
            await self._save(tokens)
        return tokens.access_token

    # ------------------------------------------------------------ API

    def _limited(self, response: httpx.Response) -> StravaRateLimited:
        usage, limit = (
            _pair(response.headers.get("X-RateLimit-Usage")),
            _pair(response.headers.get("X-RateLimit-Limit")),
        )
        daily = bool(usage and limit and usage[1] >= limit[1])
        wait = seconds_until_reset(self._clock.now(), daily=daily)
        return StravaRateLimited(detail={"retry_after_s": wait, "window": "daily" if daily else "15_minutes"})

    def _note_usage(self, response: httpx.Response) -> tuple[int, int] | None:
        usage = _pair(response.headers.get("X-RateLimit-Usage"))
        if usage is not None:
            self.last_usage = usage
        return usage

    async def _get(
        self, http: httpx.AsyncClient, path: str, params: dict[str, Any], token: str
    ) -> httpx.Response:
        return await http.get(
            f"{API_BASE}{path}", params=params, headers={"Authorization": f"Bearer {token}"}
        )

    async def fetch_activities(
        self, after: datetime | None, *, max_pages: int = MAX_PAGES
    ) -> tuple[list[WorkoutRec], StravaSyncResult]:
        token = await self._access_token()
        records: list[WorkoutRec] = []
        result = StravaSyncResult()
        refreshed = False
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT, transport=self._transport) as http:
                page = 1
                while page <= max_pages:
                    params: dict[str, Any] = {"per_page": PER_PAGE, "page": page}
                    if after is not None:
                        params["after"] = int(after.timestamp())
                    response = await self._get(http, "/athlete/activities", params, token)
                    if response.status_code == 401 and not refreshed:  # token revoked or expired early
                        refreshed = True
                        token = await self._access_token(force_refresh=True)
                        continue
                    if response.status_code == 401:
                        raise StravaReauthRequired()
                    if response.status_code == 429:
                        raise self._limited(response)
                    if response.status_code >= 400:
                        raise Unavailable(f"Strava answered {response.status_code}.")
                    items = response.json()
                    result.pages += 1
                    records += [r for item in items if isinstance(item, dict) and (r := map_activity(item))]
                    usage, limit = (
                        self._note_usage(response),
                        _pair(response.headers.get("X-RateLimit-Limit")),
                    )
                    if usage and limit:
                        result.usage_15min, result.usage_daily = usage
                        if usage[0] >= limit[0] * USAGE_STOP_RATIO or usage[1] >= limit[1] * USAGE_STOP_RATIO:
                            result.stopped_for_rate_limit = len(items) >= PER_PAGE
                            break
                    if len(items) < PER_PAGE:
                        break
                    page += 1
        except httpx.HTTPError as exc:
            raise Unavailable("Strava could not be reached.") from exc
        return records, result

    async def sync(self) -> StravaSyncResult:
        """Fetch activities newer than the last stored one and store them as restricted records."""
        after = await self._store.latest_workout_start("strava")
        records, result = await self.fetch_activities(after)
        result.created, result.updated = await self._store.upsert_external_workouts(
            records, origin="strava", restricted=True
        )
        return result
