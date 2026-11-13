"""Fitness tools. All LOW risk, read-only (they never write), data class health, permission
`health.read`. Each answer states its data source and freshness (see `results.Sourced`)."""

from __future__ import annotations

import datetime as dt
from collections.abc import Callable
from typing import Annotated, Any

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.core.types import AgentId, DataClass, RiskLevel
from app.fitness import summaries as s
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
from app.fitness.service import FitnessService, MusicHintOut, RoutineOut, RunningPlanOut
from app.schemas.common import UICard
from app.tools.spec import ToolContext, ToolSpec

PERMISSION = "health.read"
GROUP = "fitness-mcp"
AGENTS = frozenset({AgentId.FITNESS, AgentId.PERSONAL_ASSISTANT, AgentId.VOICE})
MUSIC_AGENTS = AGENTS | {AgentId.MUSIC}
LIFESTYLE_METRICS = tuple(METRICS)


class In(BaseModel):
    model_config = ConfigDict(extra="ignore")


class ScopeIn(In):
    include_strava: bool = Field(
        default=False,
        description="Also use Strava activities. The answer is then never sent to an external model.",
    )


class DailySummaryIn(ScopeIn):
    date: dt.date | None = Field(default=None, description="Local date; today when omitted.")


class WeeklyComparisonIn(ScopeIn):
    end_date: dt.date | None = Field(
        default=None, description="Last day of the current 7-day window; default the latest synced day."
    )


class TrendsIn(In):
    metric: str = Field(default="steps", description="One of: " + ", ".join(LIFESTYLE_METRICS))
    days: Annotated[int, Field(ge=7, le=180)] = 28

    @model_validator(mode="after")
    def _known_metric(self) -> TrendsIn:
        if self.metric not in METRICS:
            raise ValueError(f"metric must be one of {', '.join(LIFESTYLE_METRICS)}")
        return self


class RunningProgressIn(ScopeIn):
    days: Annotated[int, Field(ge=14, le=365)] = 90


class RecordsIn(ScopeIn):
    pass


class ConsistencyIn(ScopeIn):
    weeks: Annotated[int, Field(ge=2, le=26)] = 8
    min_active_minutes: Annotated[int, Field(ge=5, le=120)] = 20
    target_sessions_per_week: Annotated[int, Field(ge=1, le=14)] = 3


class RunningPlanIn(In):
    goal: Goal = "first_5k"
    weeks: Annotated[int, Field(ge=4, le=20)] | None = None
    days_per_week: Annotated[int, Field(ge=2, le=6)] = 3
    current_weekly_km: Annotated[float, Field(ge=0, le=200, allow_inf_nan=False)] | None = None


class RoutineIn(In):
    goal: RoutineGoal = "general"
    days_per_week: Annotated[int, Field(ge=2, le=6)] = 3
    minutes: Annotated[int, Field(ge=20, le=120)] = 45
    equipment: Equipment = "none"
    level: Level = "beginner"


class MusicHintIn(In):
    workout_type: str = Field(
        default="running", pattern="^(running|walking|cycling|strength|yoga|swimming|other)$"
    )
    pace_s_per_km: Annotated[float, Field(gt=0, le=1800, allow_inf_nan=False)] | None = None
    duration_min: Annotated[float, Field(gt=0, le=600, allow_inf_nan=False)] | None = None


def _tz(ctx: ToolContext) -> str:
    return ctx.timezone or "Asia/Kolkata"


def _card(title: str) -> Callable[[Any], UICard | None]:
    return lambda r: s.card(r, title)


def build_tools(svc: FitnessService) -> list[ToolSpec]:
    async def daily(ctx: ToolContext, a: DailySummaryIn) -> DailySummary:
        return await svc.daily_summary(ctx.now(), _tz(ctx), a.date, include_strava=a.include_strava)

    async def weekly(ctx: ToolContext, a: WeeklyComparisonIn) -> WeeklyComparison:
        return await svc.weekly_comparison(ctx.now(), _tz(ctx), a.end_date, include_strava=a.include_strava)

    async def trends(ctx: ToolContext, a: TrendsIn) -> TrendResult:
        return await svc.trend(ctx.now(), _tz(ctx), a.metric, a.days)

    async def running(ctx: ToolContext, a: RunningProgressIn) -> RunningProgress:
        return await svc.running_progress(ctx.now(), _tz(ctx), a.days, include_strava=a.include_strava)

    async def records(ctx: ToolContext, a: RecordsIn) -> PersonalRecords:
        return await svc.personal_records(ctx.now(), include_strava=a.include_strava)

    async def consistency(ctx: ToolContext, a: ConsistencyIn) -> Consistency:
        return await svc.consistency(
            ctx.now(),
            _tz(ctx),
            a.weeks,
            min_active_minutes=a.min_active_minutes,
            target=a.target_sessions_per_week,
            include_strava=a.include_strava,
        )

    async def plan(ctx: ToolContext, a: RunningPlanIn) -> RunningPlanOut:
        return await svc.running_plan(
            ctx.now(),
            _tz(ctx),
            a.goal,
            weeks=a.weeks,
            days_per_week=a.days_per_week,
            current_weekly_km=a.current_weekly_km,
        )

    async def routine(ctx: ToolContext, a: RoutineIn) -> RoutineOut:
        return await svc.routine(
            ctx.now(),
            a.goal,
            days_per_week=a.days_per_week,
            minutes=a.minutes,
            equipment=a.equipment,
            level=a.level,
        )

    async def music(ctx: ToolContext, a: MusicHintIn) -> MusicHintOut:
        return await svc.music(
            ctx.now(), _tz(ctx), a.workout_type, pace_s_per_km=a.pace_s_per_km, duration_min=a.duration_min
        )

    def spec(
        name: str,
        description: str,
        inp: type[BaseModel],
        out: type[BaseModel],
        handler: Any,
        summarizer: Any,
        title: str,
        *,
        agents: frozenset[AgentId] = AGENTS,
    ) -> ToolSpec:
        return ToolSpec(
            name=name,
            description=description,
            input_model=inp,
            output_model=out,
            handler=handler,
            risk=RiskLevel.LOW,
            data_classes=frozenset({DataClass.HEALTH}),
            permission=PERMISSION,
            agents=agents,
            mcp_group=GROUP,
            summarizer=summarizer,
            card=_card(title),
        )

    return [
        spec(
            "fitness.daily_summary",
            "Steps, distance, energy, exercise, heart rate and sleep for one day, from synced Apple Health data.",
            DailySummaryIn,
            DailySummary,
            daily,
            s.daily,
            "Daily summary",
        ),
        spec(
            "fitness.weekly_comparison",
            "Compare the last 7 days with the 7 days before (averages and change).",
            WeeklyComparisonIn,
            WeeklyComparison,
            weekly,
            s.weekly,
            "This week vs last week",
        ),
        spec(
            "fitness.trends",
            "Trend of one metric over a window (least-squares slope; needs at least 7 data points).",
            TrendsIn,
            TrendResult,
            trends,
            s.trend,
            "Trend",
        ),
        spec(
            "fitness.running_progress",
            "Running totals and pace trend over a window (needs at least 4 runs with pace).",
            RunningProgressIn,
            RunningProgress,
            running,
            s.running,
            "Running progress",
        ),
        spec(
            "fitness.personal_records",
            "Personal bests: longest run, fastest pace, best days.",
            RecordsIn,
            PersonalRecords,
            records,
            s.records,
            "Personal records",
        ),
        spec(
            "fitness.consistency",
            "Active days, streaks and sessions per week.",
            ConsistencyIn,
            Consistency,
            consistency,
            s.consistency,
            "Consistency",
        ),
        spec(
            "fitness.build_running_plan",
            "Build a progressive running plan from the owner's goal and current volume (rule based).",
            RunningPlanIn,
            RunningPlanOut,
            plan,
            s.plan,
            "Running plan",
        ),
        spec(
            "fitness.build_routine",
            "Build a weekly strength or general exercise routine (rule based).",
            RoutineIn,
            RoutineOut,
            routine,
            s.routine,
            "Exercise routine",
        ),
        spec(
            "fitness.music_hint",
            "Tempo range and mood words for workout music, for the music agent.",
            MusicHintIn,
            MusicHintOut,
            music,
            s.music,
            "Workout music",
            agents=MUSIC_AGENTS,
        ),
    ]
