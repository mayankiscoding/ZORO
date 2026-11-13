"""`/v1/fitness` routes. Thin: every rule lives in `FitnessService`, the store and the Strava adapter."""

from __future__ import annotations

import datetime as dt
import secrets
from collections.abc import Awaitable, Callable
from datetime import timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field

from app.core.errors import BadRequest, Forbidden
from app.fitness.analytics import METRICS
from app.fitness.plans import Goal
from app.fitness.results import (
    Consistency,
    DailySummary,
    PersonalRecords,
    RunningProgress,
    TrendResult,
    WeeklyComparison,
)
from app.fitness.routines import Equipment, Level, RoutineGoal
from app.fitness.schemas import FModel, Freshness, SyncIn, SyncOut
from app.fitness.service import FitnessService, MusicHintOut, RoutineOut, RunningPlanOut
from app.fitness.strava import StravaAdapter, StravaSyncResult

PERMISSION = "health.read"
STATE_TTL = timedelta(minutes=10)


class StravaStatus(FModel):
    configured: bool
    connected: bool
    external_model_allowed: bool = False


class AuthorizeUrl(FModel):
    url: str
    state: str


class StravaCallback(FModel):
    code: str
    state: str


class PlanBody(BaseModel):
    goal: Goal = "first_5k"
    weeks: Annotated[int, Field(ge=4, le=20)] | None = None
    days_per_week: Annotated[int, Field(ge=2, le=6)] = 3
    current_weekly_km: Annotated[float, Field(ge=0, le=200)] | None = None


class RoutineBody(BaseModel):
    goal: RoutineGoal = "general"
    days_per_week: Annotated[int, Field(ge=2, le=6)] = 3
    minutes: Annotated[int, Field(ge=20, le=120)] = 45
    equipment: Equipment = "none"
    level: Level = "beginner"


def build_router(
    reg: Any, svc: FitnessService, strava: StravaAdapter, require_device: Callable[..., Awaitable[Any]]
) -> APIRouter:
    router = APIRouter(prefix="/fitness", tags=["fitness"], dependencies=[Depends(require_device)])
    pending_states: dict[str, Any] = {}

    async def can_read() -> None:
        if not await reg.service("permissions").is_granted(PERMISSION):
            raise Forbidden(
                f"Allow '{PERMISSION}' in Security and privacy first.",
                code=f"permission_not_granted:{PERMISSION}",
            )

    read = [Depends(can_read)]
    Tz = Annotated[str, Query(max_length=64)]

    def now() -> Any:
        return reg.service("clock").now()

    @router.post("/sync", response_model=SyncOut)
    async def sync(body: SyncIn) -> SyncOut:
        return await svc.store.apply_sync(body)

    @router.get("/freshness", response_model=Freshness)
    async def freshness() -> Freshness:
        return await svc.freshness()

    @router.get("/summary", response_model=DailySummary, dependencies=read)
    async def summary(
        date_: Annotated[dt.date | None, Query(alias="date")] = None,
        include_strava: bool = False,
        tz: Tz = "Asia/Kolkata",
    ) -> DailySummary:
        return await svc.daily_summary(now(), tz, date_, include_strava=include_strava)

    @router.get("/weekly", response_model=WeeklyComparison, dependencies=read)
    async def weekly(
        end_date: dt.date | None = None, include_strava: bool = False, tz: Tz = "Asia/Kolkata"
    ) -> WeeklyComparison:
        return await svc.weekly_comparison(now(), tz, end_date, include_strava=include_strava)

    @router.get("/trends", response_model=TrendResult, dependencies=read)
    async def trends(
        metric: str = "steps", days: Annotated[int, Query(ge=7, le=180)] = 28, tz: Tz = "Asia/Kolkata"
    ) -> TrendResult:
        if metric not in METRICS:
            raise BadRequest(f"metric must be one of {', '.join(METRICS)}")
        return await svc.trend(now(), tz, metric, days)

    @router.get("/running", response_model=RunningProgress, dependencies=read)
    async def running(
        days: Annotated[int, Query(ge=14, le=365)] = 90, include_strava: bool = False, tz: Tz = "Asia/Kolkata"
    ) -> RunningProgress:
        return await svc.running_progress(now(), tz, days, include_strava=include_strava)

    @router.get("/records", response_model=PersonalRecords, dependencies=read)
    async def records(include_strava: bool = False) -> PersonalRecords:
        return await svc.personal_records(now(), include_strava=include_strava)

    @router.get("/consistency", response_model=Consistency, dependencies=read)
    async def consistency(
        weeks: Annotated[int, Query(ge=2, le=26)] = 8,
        min_active_minutes: Annotated[int, Query(ge=5, le=120)] = 20,
        target: Annotated[int, Query(ge=1, le=14)] = 3,
        include_strava: bool = False,
        tz: Tz = "Asia/Kolkata",
    ) -> Consistency:
        return await svc.consistency(
            now(),
            tz,
            weeks,
            min_active_minutes=min_active_minutes,
            target=target,
            include_strava=include_strava,
        )

    @router.post("/running-plan", response_model=RunningPlanOut, dependencies=read)
    async def running_plan(body: PlanBody, tz: Tz = "Asia/Kolkata") -> RunningPlanOut:
        return await svc.running_plan(
            now(),
            tz,
            body.goal,
            weeks=body.weeks,
            days_per_week=body.days_per_week,
            current_weekly_km=body.current_weekly_km,
        )

    @router.post("/routine", response_model=RoutineOut, dependencies=read)
    async def routine(body: RoutineBody) -> RoutineOut:
        return await svc.routine(
            now(),
            body.goal,
            days_per_week=body.days_per_week,
            minutes=body.minutes,
            equipment=body.equipment,
            level=body.level,
        )

    @router.get("/music-hint", response_model=MusicHintOut, dependencies=read)
    async def music_hint(
        workout_type: str = "running", pace_s_per_km: float | None = None, tz: Tz = "Asia/Kolkata"
    ) -> MusicHintOut:
        return await svc.music(now(), tz, workout_type, pace_s_per_km=pace_s_per_km)

    # ------------------------------------------------------------ Strava

    @router.get("/strava/status", response_model=StravaStatus)
    async def strava_status() -> StravaStatus:
        await strava.refresh_state()
        return StravaStatus(configured=strava.configured, connected=strava.connected)

    @router.get("/strava/authorize-url", response_model=AuthorizeUrl)
    async def strava_authorize(redirect_uri: Annotated[str, Query(max_length=300)]) -> AuthorizeUrl:
        state = secrets.token_urlsafe(24)
        moment = now()
        for key in [k for k, v in pending_states.items() if v < moment]:
            del pending_states[key]
        url = strava.authorize_url(redirect_uri, state)  # raises when not configured
        pending_states[state] = moment + STATE_TTL
        return AuthorizeUrl(url=url, state=state)

    @router.post("/strava/callback", response_model=StravaStatus)
    async def strava_callback(body: StravaCallback) -> StravaStatus:
        expires = pending_states.pop(body.state, None)
        if expires is None or expires < now():
            raise BadRequest("The Strava sign-in expired. Start again.", code="strava_state_invalid")
        await strava.exchange_code(body.code)
        return StravaStatus(configured=True, connected=True)

    @router.post("/strava/sync", response_model=StravaSyncResult)
    async def strava_sync() -> StravaSyncResult:
        return await strava.sync()

    @router.delete("/strava", response_model=StravaStatus)
    async def strava_disconnect() -> StravaStatus:
        await strava.disconnect()
        return StravaStatus(configured=strava.configured, connected=False)

    return router
