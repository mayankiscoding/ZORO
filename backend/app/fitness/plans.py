"""Rule-based running plan and exercise routine builders.

Deterministic and explainable: every plan lists the rules it used and the assumptions it had to make.
No model, no medical claims (`wording.ensure_fitness_wording` runs over every note).
"""

from __future__ import annotations

import math
from typing import Literal

from app.fitness.schemas import FModel
from app.fitness.wording import ensure_fitness_wording

Goal = Literal["first_5k", "5k", "10k", "half_marathon"]
MAX_WEEKLY_INCREASE = 0.10
DOWN_WEEK_FACTOR = 0.80
DOWN_WEEK_EVERY = 4
TAPER_FACTOR = 0.60
MIN_START_KM = 6.0
ASSUMED_START_KM = 8.0
MIN_SESSION_KM = 2.0

# goal -> (race km, peak long run km, peak weekly km, default weeks, taper last week)
GOALS: dict[str, tuple[float, float, float, int, bool]] = {
    "first_5k": (5.0, 7.0, 20.0, 8, False),
    "5k": (5.0, 9.0, 28.0, 8, False),
    "10k": (10.0, 14.0, 38.0, 10, True),
    "half_marathon": (21.1, 19.0, 50.0, 12, True),
}
DAY_LAYOUT: dict[int, tuple[str, ...]] = {
    2: ("tue", "sat"),
    3: ("tue", "thu", "sun"),
    4: ("mon", "wed", "fri", "sun"),
    5: ("mon", "tue", "thu", "fri", "sun"),
    6: ("mon", "tue", "wed", "fri", "sat", "sun"),
}


class PlanSession(FModel):
    day: str
    kind: Literal["easy", "long", "steady"]
    distance_km: float
    effort: str


class PlanWeek(FModel):
    week: int
    total_km: float
    down_week: bool = False
    taper: bool = False
    sessions: list[PlanSession]


class RunningPlan(FModel):
    goal: Goal
    race_km: float
    weeks: list[PlanWeek]
    days_per_week: int
    start_weekly_km: float
    start_basis: Literal["user_provided", "synced_runs", "assumed"]
    reaches_target_distance: bool
    rules: list[str]
    assumptions: list[str]
    notes: list[str]


def _floor_half(km: float) -> float:
    return math.floor(km * 2 + 1e-9) / 2


def weekly_totals(start_km: float, weeks: int, peak: float, taper: bool) -> list[tuple[float, bool, bool]]:
    """`(km, down_week, taper_week)` per week: +10% a week at most, a lighter week every fourth week,
    a shorter final week for the longer goals. All rounded down to 0.5 km so a rule is never exceeded."""
    out: list[tuple[float, bool, bool]] = []
    last_up = start_km
    for week in range(1, weeks + 1):
        if week == weeks and taper and weeks >= 4:
            out.append((_floor_half(last_up * TAPER_FACTOR), False, True))
        elif week % DOWN_WEEK_EVERY == 0 and week != weeks:
            out.append((_floor_half(last_up * DOWN_WEEK_FACTOR), True, False))
        else:
            km = start_km if week == 1 else min(peak, last_up * (1 + MAX_WEEKLY_INCREASE))
            km = max(_floor_half(km), 1.0)
            if week > 1 and km < last_up:
                km = last_up
            last_up = km
            out.append((km, False, False))
    return out


def _sessions(total: float, days: int, long_cap: float, *, down: bool, easy_note: str) -> list[PlanSession]:
    layout = DAY_LAYOUT[days]
    long_share = 0.40 if days <= 3 else 0.35
    long_km = min(_floor_half(total * long_share), long_cap)
    long_km = max(long_km, MIN_SESSION_KM)
    rest = max(total - long_km, 0.0)
    others = days - 1
    each = max(_floor_half(rest / others), MIN_SESSION_KM) if others else 0
    sessions: list[PlanSession] = []
    for index, day in enumerate(layout[:-1]):
        steady = days >= 4 and index == 1 and not down  # one steady session a week from four days up
        sessions.append(
            PlanSession(
                day=day,
                kind="steady" if steady else "easy",
                distance_km=each,
                effort="comfortably hard, you can say short sentences" if steady else easy_note,
            )
        )
    sessions.append(
        PlanSession(
            day=layout[-1], kind="long", distance_km=long_km, effort="easy and even, walk breaks are fine"
        )
    )
    return sessions


def build_running_plan(
    goal: Goal = "first_5k",
    *,
    weeks: int | None = None,
    days_per_week: int = 3,
    current_weekly_km: float | None = None,
    synced_weekly_km: float | None = None,
    recent_pace_text: str | None = None,
) -> RunningPlan:
    race_km, peak_long, peak_weekly, default_weeks, taper = GOALS[goal]
    n_weeks = weeks or default_weeks
    assumptions: list[str] = []
    if current_weekly_km is not None:
        start, basis = current_weekly_km, "user_provided"
        assumptions.append(f"Your current running volume is {current_weekly_km:g} km a week, as you told me.")
    elif synced_weekly_km is not None and synced_weekly_km > 0:
        start, basis = synced_weekly_km, "synced_runs"
        assumptions.append(
            f"Your current running volume is {synced_weekly_km:g} km a week, the average of your last 4 synced weeks."
        )
    else:
        start, basis = ASSUMED_START_KM, "assumed"
        assumptions.append(
            f"No running volume was given or synced, so the plan starts at {ASSUMED_START_KM:g} km a week."
        )
    if start < MIN_START_KM and basis != "assumed":
        assumptions.append(
            f"The plan starts at {MIN_START_KM:g} km a week, the lowest start this builder uses."
        )
        start = MIN_START_KM
    start = min(start, peak_weekly)
    easy_note = "easy, you can hold a conversation"
    if recent_pace_text:
        assumptions.append(
            f"Your recent average pace is {recent_pace_text} per km; easy runs should feel no harder than that."
        )
    assumptions.append(f"You can run {days_per_week} days a week and rest on the other days.")

    totals = weekly_totals(start, n_weeks, peak_weekly, taper)
    plan_weeks: list[PlanWeek] = []
    for number, (km, down, is_taper) in enumerate(totals, start=1):
        plan_weeks.append(
            PlanWeek(
                week=number,
                total_km=km,
                down_week=down,
                taper=is_taper,
                sessions=_sessions(km, days_per_week, peak_long, down=down or is_taper, easy_note=easy_note),
            )
        )
    longest = max(s.distance_km for w in plan_weeks for s in w.sessions if s.kind == "long")
    reaches = longest >= min(race_km, peak_long) - 0.5
    rules = [
        f"Weekly distance rises by at most {MAX_WEEKLY_INCREASE:.0%} compared with the last regular week.",
        f"Every {DOWN_WEEK_EVERY}th week is a lighter week at {DOWN_WEEK_FACTOR:.0%} of the previous regular week.",
        "The long run is about 35 to 40 percent of the week, capped for the goal.",
    ]
    if taper:
        rules.append(f"The final week is a shorter race week at {TAPER_FACTOR:.0%} of the last regular week.")
    notes = [
        "This is a training outline, not medical advice. Adjust it to how you feel.",
        "If something hurts, stop and rest; repeat a week instead of adding distance.",
    ]
    if not reaches:
        notes.append(
            f"In {n_weeks} weeks at this start the long run reaches {longest:g} km, short of the {race_km:g} km goal; "
            "a longer plan would get you there."
        )
    for line in (*assumptions, *rules, *notes):
        ensure_fitness_wording(line)
    return RunningPlan(
        goal=goal,
        race_km=race_km,
        weeks=plan_weeks,
        days_per_week=days_per_week,
        start_weekly_km=start,
        start_basis=basis,
        reaches_target_distance=reaches,
        rules=rules,
        assumptions=assumptions,
        notes=notes,
    )
