"""Fitness persistence: upsert by date and by workout id, range reads, sync state."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date, datetime, timedelta

from sqlalchemy import func, select

from app.core.clock import Clock
from app.db.session import SessionFactory
from app.fitness.models import FitnessDay, FitnessSyncLog, FitnessWorkout
from app.fitness.records import DayRec, SyncState, WorkoutRec
from app.fitness.schemas import DayIn, SyncIn, SyncOut, WorkoutIn

DAY_FIELDS = (
    "steps",
    "walking_running_distance_m",
    "cycling_distance_m",
    "active_energy_kcal",
    "exercise_minutes",
    "resting_heart_rate_bpm",
    "avg_heart_rate_bpm",
    "sleep_minutes",
    "body_mass_kg",
)
WORKOUT_FIELDS = (
    "type",
    "end_at",
    "duration_s",
    "distance_m",
    "active_energy_kcal",
    "avg_heart_rate_bpm",
    "avg_pace_s_per_km",
    "source",
)


def _day_rec(row: FitnessDay) -> DayRec:
    return DayRec(**{f: getattr(row, f) for f in ("date", *DAY_FIELDS)}, sources=tuple(row.sources or ()))


def _workout_rec(row: FitnessWorkout) -> WorkoutRec:
    return WorkoutRec(
        id=row.id,
        type=row.type,
        start_at=row.start_at,
        local_date=row.local_date,
        origin=row.origin,
        end_at=row.end_at,
        duration_s=row.duration_s,
        distance_m=row.distance_m,
        active_energy_kcal=row.active_energy_kcal,
        avg_heart_rate_bpm=row.avg_heart_rate_bpm,
        avg_pace_s_per_km=row.avg_pace_s_per_km,
        source=row.source,
    )


class FitnessStore:
    def __init__(self, session_factory: SessionFactory, clock: Clock) -> None:
        self._sf = session_factory
        self._clock = clock
        self.has_synced = False  # read by the capability entry; refreshed at startup and on every sync

    async def refresh_state(self) -> None:
        self.has_synced = (await self.sync_state()).last_synced_at is not None

    # ------------------------------------------------------------ writes

    async def apply_sync(self, payload: SyncIn) -> SyncOut:
        """Upsert aggregates. A row is replaced as a whole, so a null in the payload stays null.
        A payload older than what is stored for that row never overwrites it."""
        now = self._clock.now()
        generated = payload.generated_at.astimezone(now.tzinfo)
        days: dict[date, DayIn] = {d.date: d for d in payload.days}  # a repeated date: the last one wins
        workouts: dict[str, WorkoutIn] = {w.id: w for w in payload.workouts}
        counts = dict.fromkeys(("dc", "du", "ds", "wc", "wu", "ws"), 0)
        async with self._sf() as session:
            existing_days = (
                {
                    r.date: r
                    for r in (
                        await session.scalars(select(FitnessDay).where(FitnessDay.date.in_(list(days))))
                    ).all()
                }
                if days
                else {}
            )
            for d, item in days.items():
                row = existing_days.get(d)
                if row is not None and row.source_generated_at > generated:
                    counts["ds"] += 1
                    continue
                if row is None:
                    row = FitnessDay(date=d)
                    session.add(row)
                    counts["dc"] += 1
                else:
                    counts["du"] += 1
                for f in DAY_FIELDS:
                    setattr(row, f, getattr(item, f))
                row.sources = list(item.sources)
                row.source_generated_at, row.synced_at = generated, now
            existing_w = (
                {
                    r.id: r
                    for r in (
                        await session.scalars(
                            select(FitnessWorkout).where(FitnessWorkout.id.in_(list(workouts)))
                        )
                    ).all()
                }
                if workouts
                else {}
            )
            for wid, w in workouts.items():
                wrow = existing_w.get(wid)
                if wrow is not None and wrow.source_generated_at > generated:
                    counts["ws"] += 1
                    continue
                if wrow is None:
                    wrow = FitnessWorkout(id=wid, origin="healthkit", ai_restricted=False)
                    session.add(wrow)
                    counts["wc"] += 1
                else:
                    counts["wu"] += 1
                for f in WORKOUT_FIELDS:
                    setattr(wrow, f, getattr(w, f))
                wrow.start_at = w.start_at
                wrow.local_date = w.start_at.date()  # the date on the device's own clock (its UTC offset)
                wrow.source_generated_at, wrow.synced_at = generated, now
            session.add(
                FitnessSyncLog(
                    origin="healthkit",
                    received_at=now,
                    generated_at=generated,
                    days_count=len(days),
                    workouts_count=len(workouts),
                )
            )
            await session.commit()
        self.has_synced = True
        return SyncOut(
            received_at=now,
            generated_at=generated,
            days_created=counts["dc"],
            days_updated=counts["du"],
            days_skipped_older=counts["ds"],
            workouts_created=counts["wc"],
            workouts_updated=counts["wu"],
            workouts_skipped_older=counts["ws"],
        )

    async def upsert_external_workouts(
        self, items: Sequence[WorkoutRec], *, origin: str, restricted: bool
    ) -> tuple[int, int]:
        """Store workouts from another service (Strava). Returns (created, updated)."""
        now = self._clock.now()
        created = updated = 0
        async with self._sf() as session:
            ids = [w.id for w in items]
            existing = (
                {
                    r.id: r
                    for r in (
                        await session.scalars(select(FitnessWorkout).where(FitnessWorkout.id.in_(ids)))
                    ).all()
                }
                if ids
                else {}
            )
            for w in items:
                row = existing.get(w.id)
                if row is None:
                    row = FitnessWorkout(id=w.id, origin=origin)
                    session.add(row)
                    created += 1
                else:
                    updated += 1
                for f in WORKOUT_FIELDS:
                    setattr(row, f, getattr(w, f))
                row.start_at, row.local_date = w.start_at, w.local_date
                row.ai_restricted = restricted
                row.source_generated_at = row.synced_at = now
            session.add(
                FitnessSyncLog(
                    origin=origin, received_at=now, generated_at=now, days_count=0, workouts_count=len(items)
                )
            )
            await session.commit()
        return created, updated

    # ------------------------------------------------------------ reads

    async def days(self, start: date, end: date) -> list[DayRec]:
        async with self._sf() as session:
            rows = await session.scalars(
                select(FitnessDay)
                .where(FitnessDay.date >= start, FitnessDay.date <= end)
                .order_by(FitnessDay.date)
            )
            return [_day_rec(r) for r in rows.all()]

    async def workouts(
        self, start: date | None, end: date | None, *, include_strava: bool = False
    ) -> list[WorkoutRec]:
        stmt = select(FitnessWorkout).order_by(FitnessWorkout.start_at)
        if start is not None:
            stmt = stmt.where(FitnessWorkout.local_date >= start)
        if end is not None:
            stmt = stmt.where(FitnessWorkout.local_date <= end)
        if not include_strava:
            stmt = stmt.where(FitnessWorkout.ai_restricted.is_(False))
        async with self._sf() as session:
            return [_workout_rec(r) for r in (await session.scalars(stmt)).all()]

    async def latest_workout_start(self, origin: str) -> datetime | None:
        async with self._sf() as session:
            return (
                await session.execute(
                    select(func.max(FitnessWorkout.start_at)).where(FitnessWorkout.origin == origin)
                )
            ).scalar_one()

    async def sync_state(self) -> SyncState:
        async with self._sf() as session:
            last = (
                await session.execute(
                    select(func.max(FitnessSyncLog.received_at), func.max(FitnessSyncLog.generated_at)).where(
                        FitnessSyncLog.origin == "healthkit"
                    )
                )
            ).one()
            latest_day = (await session.execute(select(func.max(FitnessDay.date)))).scalar_one()
        return SyncState(last_synced_at=last[0], last_generated_at=last[1], latest_day=latest_day)

    async def source_names(self, start: date, end: date) -> list[str]:
        names: set[str] = set()
        for d in await self.days(start, end):
            names.update(d.sources)
        return sorted(names)


def age_of(moment: datetime | None, now: datetime) -> tuple[int | None, str | None]:
    """(value, unit) for "synced N minutes / hours / days ago"."""
    if moment is None:
        return None, None
    seconds = max((now - moment).total_seconds(), 0.0)
    if seconds < 3600:
        return int(seconds // 60), "minutes"
    if seconds < 2 * 86400:
        return int(seconds // 3600), "hours"
    return int(seconds // 86400), "days"


STALE_AFTER = timedelta(hours=36)
