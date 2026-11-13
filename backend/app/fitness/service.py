"""FitnessService: loads data, runs the analytics, stamps every answer with source and freshness."""

from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import TypeVar
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.core.clock import Clock
from app.fitness import analytics as a
from app.fitness.plans import Goal, RunningPlan, build_running_plan
from app.fitness.records import DayRec, WorkoutRec
from app.fitness.results import (
    Consistency,
    DailySummary,
    PersonalRecords,
    RunningProgress,
    Sourced,
    TrendResult,
    WeeklyComparison,
)
from app.fitness.routines import (
    Equipment,
    ExerciseRoutine,
    Level,
    MusicHint,
    RoutineGoal,
    build_exercise_routine,
    music_hint,
)
from app.fitness.schemas import Freshness
from app.fitness.stats import pace_text
from app.fitness.store import STALE_AFTER, FitnessStore, age_of

S = TypeVar("S", bound=Sourced)
APPLE_HEALTH = "Apple Health (synced from your iPhone)"
HISTORY_DAYS = 35  # what the recovery observations look back over


class RunningPlanOut(Sourced):
    plan: RunningPlan | None = None


class RoutineOut(Sourced):
    routine: ExerciseRoutine | None = None


class MusicHintOut(Sourced):
    hint: MusicHint | None = None


def local_today(now: datetime, tz: str) -> date:
    try:
        zone = ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError):
        zone = ZoneInfo("Asia/Kolkata")
    return now.astimezone(zone).date()


class FitnessService:
    def __init__(self, store: FitnessStore, clock: Clock) -> None:
        self.store = store
        self._clock = clock

    # ------------------------------------------------------------ stamping

    async def freshness(self, now: datetime | None = None) -> Freshness:
        now = now or self._clock.now()
        state = await self.store.sync_state()
        value, unit = age_of(state.last_synced_at, now)
        stale = state.last_synced_at is None or now - state.last_synced_at > STALE_AFTER
        return Freshness(
            last_synced_at=state.last_synced_at,
            latest_data_date=state.latest_day,
            age_value=value,
            age_unit=unit,
            stale=stale,
        )

    async def _stamp(
        self, result: S, now: datetime, workouts: list[WorkoutRec], devices: list[str] | None = None
    ) -> S:
        fresh = await self.freshness(now)
        strava = any(w.origin == "strava" for w in workouts)
        names = sorted({*(devices or []), *(w.source for w in workouts if w.source and w.origin != "strava")})
        source = APPLE_HEALTH + (" and Strava" if strava else "")
        reason = result.reason
        if fresh.last_synced_at is None and not result.available:
            reason = "never_synced"
        return result.model_copy(
            update={
                "freshness": fresh,
                "data_source": source,
                "devices": names,
                "external_model_allowed": not strava,
                "reason": reason,
            }
        )

    async def _unavailable(self, model: type[S], now: datetime, reason: str, **fields: object) -> S:
        return await self._stamp(model(available=False, reason=reason, **fields), now, [])

    # ------------------------------------------------------------ analytics

    async def daily_summary(
        self, now: datetime, tz: str, day: date | None = None, *, include_strava: bool = False
    ) -> DailySummary:
        today = local_today(now, tz)
        target = day or today
        history = await self.store.days(target - timedelta(days=HISTORY_DAYS - 1), target)
        row = next((d for d in history if d.date == target), None)
        if row is None:
            return await self._unavailable(DailySummary, now, "no_data_for_date", date=target)
        workouts = await self.store.workouts(target, target, include_strava=include_strava)
        return await self._stamp(a.daily_summary(row, workouts, history), now, workouts, list(row.sources))

    async def weekly_comparison(
        self, now: datetime, tz: str, end: date | None = None, *, include_strava: bool = False
    ) -> WeeklyComparison:
        today = local_today(now, tz)
        if end is None:
            latest = (await self.store.sync_state()).latest_day
            end = min(today, latest) if latest else today
        days = await self.store.days(end - timedelta(days=HISTORY_DAYS - 1), end)
        workouts = await self.store.workouts(end - timedelta(days=13), end, include_strava=include_strava)
        result = a.weekly_comparison(days, workouts, end)
        return await self._stamp(result, now, workouts, _names(days))

    async def trend(self, now: datetime, tz: str, metric: str, days: int = 28) -> TrendResult:
        end = local_today(now, tz)
        start = end - timedelta(days=days - 1)
        rows = await self.store.days(start, end)
        return await self._stamp(a.trend(rows, metric, start, end), now, [], _names(rows))

    async def running_progress(
        self, now: datetime, tz: str, days: int = 90, *, include_strava: bool = False
    ) -> RunningProgress:
        end = local_today(now, tz)
        start = end - timedelta(days=days - 1)
        workouts = await self.store.workouts(start, end, include_strava=include_strava)
        return await self._stamp(a.running_progress(workouts, start, end), now, workouts)

    async def personal_records(self, now: datetime, *, include_strava: bool = False) -> PersonalRecords:
        days = await self.store.days(date(2000, 1, 1), date(2100, 1, 1))
        workouts = await self.store.workouts(None, None, include_strava=include_strava)
        result = a.personal_records(days, workouts)
        used = (
            workouts
            if any(r.workout_id and r.workout_id.startswith("strava:") for r in result.records)
            else [w for w in workouts if w.origin != "strava"]
        )
        return await self._stamp(result, now, used, _names(days))

    async def consistency(
        self,
        now: datetime,
        tz: str,
        weeks: int = 8,
        *,
        min_active_minutes: int = 20,
        target: int = 3,
        include_strava: bool = False,
    ) -> Consistency:
        end = local_today(now, tz)
        start = end - timedelta(days=weeks * 7 - 1)
        days = await self.store.days(start, end)
        workouts = await self.store.workouts(start, end, include_strava=include_strava)
        result = a.consistency(
            days, workouts, start, end, min_active_minutes=min_active_minutes, target=target
        )
        return await self._stamp(result, now, workouts, _names(days))

    # ------------------------------------------------------------ builders

    async def _synced_weekly_km(self, now: datetime, tz: str) -> tuple[float | None, str | None]:
        end = local_today(now, tz)
        runs = [w for w in await self.store.workouts(end - timedelta(days=27), end) if w.type == "running"]
        if not runs:
            return None, None
        km = sum((w.distance_m or 0) / 1000.0 for w in runs) / 4
        paced = [p for w in runs if (p := w.pace_s_per_km)]
        return round(km, 1), pace_text(sum(paced) / len(paced)) if paced else None

    async def running_plan(
        self,
        now: datetime,
        tz: str,
        goal: Goal = "first_5k",
        *,
        weeks: int | None = None,
        days_per_week: int = 3,
        current_weekly_km: float | None = None,
    ) -> RunningPlanOut:
        synced, pace = (None, None)
        if current_weekly_km is None:
            synced, pace = await self._synced_weekly_km(now, tz)
        plan = build_running_plan(
            goal,
            weeks=weeks,
            days_per_week=days_per_week,
            current_weekly_km=current_weekly_km,
            synced_weekly_km=synced,
            recent_pace_text=pace,
        )
        out = await self._stamp(RunningPlanOut(plan=plan), now, [])
        if plan.start_basis != "synced_runs":
            out = out.model_copy(update={"data_source": "Plan rules and your inputs; no synced data used"})
        return out

    async def routine(
        self,
        now: datetime,
        goal: RoutineGoal = "general",
        *,
        days_per_week: int = 3,
        minutes: int = 45,
        equipment: Equipment = "none",
        level: Level = "beginner",
    ) -> RoutineOut:
        routine = build_exercise_routine(
            goal, days_per_week=days_per_week, minutes=minutes, equipment=equipment, level=level
        )
        out = await self._stamp(RoutineOut(routine=routine), now, [])
        return out.model_copy(update={"data_source": "Routine rules and your inputs; no health data used"})

    async def music(
        self,
        now: datetime,
        tz: str,
        workout_type: str,
        *,
        pace_s_per_km: float | None = None,
        duration_min: float | None = None,
    ) -> MusicHintOut:
        used_recent = False
        if workout_type == "running" and pace_s_per_km is None:
            end = local_today(now, tz)
            runs = [
                w for w in await self.store.workouts(end - timedelta(days=60), end) if w.type == "running"
            ]
            paced = [p for w in runs[-5:] if (p := w.pace_s_per_km)]
            if paced:
                pace_s_per_km, used_recent = sum(paced) / len(paced), True
        hint = music_hint(workout_type, pace_s_per_km=pace_s_per_km, duration_min=duration_min)
        if used_recent:
            hint = hint.model_copy(
                update={"assumptions": [*hint.assumptions, "The pace is your average over your last runs."]}
            )
        out = await self._stamp(MusicHintOut(hint=hint), now, [])
        if not used_recent:
            out = out.model_copy(update={"data_source": "Tempo rules and your inputs; no health data used"})
        return out


def _names(days: list[DayRec]) -> list[str]:
    return sorted({s for d in days for s in d.sources})
