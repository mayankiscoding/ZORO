"""Rule-based exercise routine builder and workout-to-music hints.

Deterministic and explainable: every routine lists the rules it used and the assumptions it made.
No model, no medical claims (`wording.ensure_fitness_wording` runs over every note).
"""

from __future__ import annotations

import math
from typing import Literal

from pydantic import Field

from app.fitness.schemas import FModel
from app.fitness.wording import ensure_fitness_wording

# ---------------------------------------------------------------- exercise routine

RoutineGoal = Literal["strength", "general", "endurance"]
Equipment = Literal["none", "dumbbells", "gym"]
Level = Literal["beginner", "intermediate"]

# movement pattern -> exercises per equipment
CATALOG: dict[str, dict[str, tuple[str, ...]]] = {
    "squat": {
        "none": ("Bodyweight squat", "Split squat"),
        "dumbbells": ("Goblet squat", "Dumbbell lunge"),
        "gym": ("Back squat", "Leg press"),
    },
    "hinge": {
        "none": ("Glute bridge", "Good morning"),
        "dumbbells": ("Dumbbell Romanian deadlift", "Hip thrust"),
        "gym": ("Deadlift", "Romanian deadlift"),
    },
    "push": {
        "none": ("Push-up", "Pike push-up"),
        "dumbbells": ("Dumbbell bench press", "Dumbbell shoulder press"),
        "gym": ("Bench press", "Overhead press"),
    },
    "pull": {
        "none": ("Inverted row under a table", "Superman hold"),
        "dumbbells": ("One-arm dumbbell row", "Reverse fly"),
        "gym": ("Lat pulldown", "Seated cable row"),
    },
    "core": {
        "none": ("Plank", "Dead bug"),
        "dumbbells": ("Plank", "Weighted dead bug"),
        "gym": ("Cable crunch", "Plank"),
    },
}
SPLITS: dict[int, tuple[tuple[str, tuple[str, ...]], ...]] = {
    2: (
        ("Full body A", ("squat", "push", "pull", "core")),
        ("Full body B", ("hinge", "push", "pull", "core")),
    ),
    3: (
        ("Full body A", ("squat", "push", "pull", "core")),
        ("Full body B", ("hinge", "pull", "push", "core")),
        ("Full body C", ("squat", "hinge", "push", "pull")),
    ),
    4: (
        ("Lower", ("squat", "hinge", "core")),
        ("Upper", ("push", "pull", "core")),
        ("Lower", ("hinge", "squat", "core")),
        ("Upper", ("pull", "push", "core")),
    ),
    5: (
        ("Lower", ("squat", "hinge", "core")),
        ("Push", ("push", "core")),
        ("Pull", ("pull", "core")),
        ("Lower", ("hinge", "squat", "core")),
        ("Full body", ("push", "pull", "squat", "core")),
    ),
    6: (
        ("Lower", ("squat", "hinge", "core")),
        ("Push", ("push", "core")),
        ("Pull", ("pull", "core")),
        ("Lower", ("hinge", "squat", "core")),
        ("Push", ("push", "core")),
        ("Pull", ("pull", "core")),
    ),
}
REPS = {"strength": (5, 8, 120), "general": (8, 12, 75), "endurance": (12, 20, 45)}  # min, max, rest seconds
WARMUP_MIN = 5
SET_WORK_S = 45


class RoutineExercise(FModel):
    name: str
    pattern: str
    sets: int
    reps: str
    rest_s: int


class RoutineDay(FModel):
    day: int
    focus: str
    estimated_minutes: int
    exercises: list[RoutineExercise]


class ExerciseRoutine(FModel):
    goal: RoutineGoal
    days_per_week: int
    minutes_per_session: int
    days: list[RoutineDay]
    rules: list[str]
    assumptions: list[str]
    notes: list[str] = Field(default_factory=list)


def build_exercise_routine(
    goal: RoutineGoal = "general",
    *,
    days_per_week: int = 3,
    minutes: int = 45,
    equipment: Equipment = "none",
    level: Level = "beginner",
) -> ExerciseRoutine:
    lo, hi, rest = REPS[goal]
    sets = 2 if level == "beginner" else 3
    if goal == "strength" and level == "intermediate":
        sets = 4
    per_exercise_s = sets * (SET_WORK_S + rest)
    budget_s = max(minutes - WARMUP_MIN, 10) * 60
    days: list[RoutineDay] = []
    for index, (focus, patterns) in enumerate(SPLITS[days_per_week], start=1):
        wanted = [p for p in patterns]
        fit = max(1, min(len(wanted), budget_s // per_exercise_s))
        chosen = wanted[:fit]
        used: dict[str, int] = {}
        exercises: list[RoutineExercise] = []
        for pattern in chosen:
            options = CATALOG[pattern][equipment]
            pick = (
                options[used.get(pattern, 0) % len(options)]
                if index % 2
                else options[(used.get(pattern, 0) + 1) % len(options)]
            )
            used[pattern] = used.get(pattern, 0) + 1
            timed = pattern == "core" and "Plank" in pick
            exercises.append(
                RoutineExercise(
                    name=pick,
                    pattern=pattern,
                    sets=sets,
                    rest_s=rest,
                    reps="30-45 seconds" if timed else f"{lo}-{hi}",
                )
            )
        total_s = len(exercises) * per_exercise_s + WARMUP_MIN * 60
        days.append(
            RoutineDay(day=index, focus=focus, estimated_minutes=math.ceil(total_s / 60), exercises=exercises)
        )
    assumptions = [
        f"You train {days_per_week} days a week for about {minutes} minutes, with {equipment.replace('none', 'no')} equipment.",
        f"Your level is {level}: {sets} sets per exercise, about {SET_WORK_S} seconds of work per set.",
        f"A {WARMUP_MIN}-minute warm-up is included in each session's time.",
    ]
    rules = [
        "Every main movement pattern (squat, hinge, push, pull, core) is trained about twice a week.",
        f"Reps for a {goal} goal are {lo} to {hi} per set with {rest} seconds of rest.",
        "Exercises are dropped from the end of a session when your time budget runs out.",
    ]
    notes = [
        "Add weight or a rep when every set feels comfortable. If something hurts, stop and swap the exercise."
    ]
    for line in (*assumptions, *rules, *notes):
        ensure_fitness_wording(line)
    return ExerciseRoutine(
        goal=goal,
        days_per_week=days_per_week,
        minutes_per_session=minutes,
        days=days,
        rules=rules,
        assumptions=assumptions,
        notes=notes,
    )


# ---------------------------------------------------------------- workout -> music hints


class MusicHint(FModel):
    workout_type: str
    bpm_min: int
    bpm_max: int
    energy: Literal["low", "medium", "high"]
    mood_terms: list[str]
    query: str
    basis: str  # how the range was chosen, in words
    assumptions: list[str] = Field(default_factory=list)


def music_hint(
    workout_type: str, *, pace_s_per_km: float | None = None, duration_min: float | None = None
) -> MusicHint:
    """Tempo range and mood words for the music agent. Running tempo follows a pace-to-cadence rule
    (about 150 steps a minute at 7:30 per km rising to about 185 at 4:00 per km); other activities use
    fixed ranges."""
    assumptions: list[str] = []
    if workout_type == "running":
        if pace_s_per_km is None:
            cadence = 165.0
            assumptions.append(
                "No pace was given, so a typical easy-run cadence of 165 steps a minute is assumed."
            )
        else:
            clamped = min(max(pace_s_per_km, 240.0), 450.0)
            cadence = 185.0 - (clamped - 240.0) * (35.0 / 210.0)
        lo, hi, energy = round(cadence - 5), round(cadence + 5), "high" if cadence >= 170 else "medium"
        moods = ["running", "upbeat", "driving"]
        basis = "Songs near your running cadence make steps and beat line up."
    elif workout_type == "walking":
        lo, hi, energy, moods = 100, 120, "medium", ["walking", "easy", "groove"]
        basis = "Walking cadence is usually 100 to 120 steps a minute."
    elif workout_type == "cycling":
        lo, hi, energy, moods = 120, 145, "medium", ["cycling", "steady", "rhythm"]
        basis = "A steady 120 to 145 beats a minute suits a typical pedalling cadence."
    elif workout_type == "strength":
        lo, hi, energy, moods = 120, 150, "high", ["gym", "heavy", "motivation"]
        basis = "Strength sessions use a punchy 120 to 150 beats a minute."
    elif workout_type == "yoga":
        lo, hi, energy, moods = 60, 90, "low", ["calm", "ambient", "instrumental"]
        basis = "Yoga uses slow, calm music at 60 to 90 beats a minute."
    elif workout_type == "swimming":
        lo, hi, energy, moods = 110, 130, "medium", ["swim", "flow", "steady"]
        basis = "A steady 110 to 130 beats a minute suits stroke rhythm."
    else:
        lo, hi, energy, moods = 110, 140, "medium", ["workout", "energy"]
        basis = "A general workout range of 110 to 140 beats a minute."
        assumptions.append("The activity type is not specific, so a general range is used.")
    if duration_min is not None and duration_min >= 45:
        assumptions.append("A long session: start about 10 beats a minute lower and build up.")
    return MusicHint(
        workout_type=workout_type,
        bpm_min=lo,
        bpm_max=hi,
        energy=energy,
        mood_terms=moods,
        query=f"{' '.join(moods[:2])} {lo}-{hi} bpm",
        basis=basis,
        assumptions=assumptions,
    )
