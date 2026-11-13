"""The wording check, the plan builders and the music hints."""

from __future__ import annotations

import pytest

from app.fitness.observations import TEMPLATES, Observation, render_observation
from app.fitness.plans import DAY_LAYOUT, DOWN_WEEK_FACTOR, GOALS, MAX_WEEKLY_INCREASE, build_running_plan
from app.fitness.routines import CATALOG, SPLITS, build_exercise_routine, music_hint
from app.fitness.wording import WordingViolation, check_wording, clean_lines, ensure_fitness_wording

# ---------------------------------------------------------------- wording


@pytest.mark.parametrize(
    "text",
    [
        "You may have hypertension.",
        "This looks like atrial fibrillation.",
        "Your heart rate suggests an infection, take paracetamol medication.",
        "Ask for a prescription and a higher dose.",
        "That could be a symptom of sleep apnea.",
        "आपको उच्च रक्तचाप है, दवा लीजिए",
        "Yeh ek bimari ka lakshan hai, dawai lijiye",
        "I can diagnose this for you",
        "This will treat your insomnia",
    ],
)
def test_diagnosis_and_medication_language_is_blocked(text: str) -> None:
    assert check_wording(text)
    with pytest.raises(WordingViolation):
        ensure_fitness_wording(text)


@pytest.mark.parametrize(
    "text",
    [
        "Your resting heart rate is 6 bpm above your recent average, which often goes with a hard week.",
        "You slept under 6 hours on each of the last 3 nights.",
        "Add a rest day after a long run.",
        "आज हल्की दौड़ रखें",
        "Aaj halka run rakho",
    ],
)
def test_ordinary_fitness_wording_passes(text: str) -> None:
    assert check_wording(text) == []
    assert ensure_fitness_wording(text) == text


def test_clean_lines_drops_only_the_bad_ones() -> None:
    assert clean_lines(["Rest well.", "You have a disease.", "Walk more."]) == ["Rest well.", "Walk more."]


def test_every_observation_template_passes_the_check_in_every_language() -> None:
    values = {"days": 3, "delta": 6, "hours": 6, "nights": 3, "ratio_pct": 140}
    for code, templates in TEMPLATES.items():
        for lang in ("en", "hi", "hinglish"):
            assert render_observation(Observation(code=code, values=values), lang), (code, lang)
        for template in templates:
            assert check_wording(template) == [], template


def test_a_drifting_template_is_dropped_not_spoken(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(
        TEMPLATES, "rhr_above_baseline", ("This points to an infection, {days} {delta}", "x", "y")
    )
    assert (
        render_observation(Observation(code="rhr_above_baseline", values={"days": 3, "delta": 6}), "en")
        is None
    )
    assert render_observation(Observation(code="unknown"), "en") is None


# ---------------------------------------------------------------- running plan


@pytest.mark.parametrize("goal", list(GOALS))
@pytest.mark.parametrize("days", [2, 3, 5])
def test_plan_follows_its_stated_rules(goal: str, days: int) -> None:
    plan = build_running_plan(goal, days_per_week=days, current_weekly_km=12.0)  # type: ignore[arg-type]
    assert len(plan.weeks) == GOALS[goal][3] and plan.start_basis == "user_provided"
    peak_weekly = GOALS[goal][2]
    last_regular = plan.weeks[0].total_km
    assert last_regular == 12.0
    for week in plan.weeks[1:]:
        if week.down_week:
            assert week.total_km <= last_regular * DOWN_WEEK_FACTOR + 0.001
        elif week.taper:
            assert week.total_km < last_regular
        else:
            assert week.total_km <= last_regular * (1 + MAX_WEEKLY_INCREASE) + 0.001
            assert week.total_km >= last_regular and week.total_km <= peak_weekly
            last_regular = week.total_km
    for week in plan.weeks:
        assert len(week.sessions) == days
        assert [s.day for s in week.sessions] == list(DAY_LAYOUT[days])
        assert week.sessions[-1].kind == "long"
        assert max(s.distance_km for s in week.sessions) == week.sessions[-1].distance_km or days > 1
        assert week.sessions[-1].distance_km <= GOALS[goal][1]
    assert plan.weeks[3].down_week and (GOALS[goal][4] == plan.weeks[-1].taper)


def test_plan_states_assumptions_and_basis() -> None:
    assumed = build_running_plan("first_5k")
    assert assumed.start_basis == "assumed" and assumed.start_weekly_km == 8.0
    assert any("starts at 8 km a week" in line for line in assumed.assumptions)
    assert any("3 days a week" in line for line in assumed.assumptions) and assumed.notes and assumed.rules
    synced = build_running_plan("10k", synced_weekly_km=14.5, recent_pace_text="6:10")
    assert synced.start_basis == "synced_runs" and synced.weeks[0].total_km == 14.5
    assert any("6:10" in line for line in synced.assumptions)
    tiny = build_running_plan("5k", current_weekly_km=2.0)
    assert tiny.start_weekly_km == 6.0 and any("lowest start" in line for line in tiny.assumptions)
    for line in (*assumed.assumptions, *assumed.rules, *assumed.notes):
        assert check_wording(line) == []


def test_short_plan_says_it_may_not_reach_the_goal() -> None:
    plan = build_running_plan("half_marathon", weeks=4, current_weekly_km=8.0)
    assert not plan.reaches_target_distance and any("short of" in note for note in plan.notes)
    long_plan = build_running_plan("half_marathon", weeks=16, current_weekly_km=20.0)
    assert long_plan.reaches_target_distance


def test_long_run_never_exceeds_the_cap_and_sessions_have_a_minimum() -> None:
    plan = build_running_plan("first_5k", weeks=20, days_per_week=6, current_weekly_km=30.0)
    assert all(s.distance_km >= 2.0 for w in plan.weeks for s in w.sessions)
    assert max(w.sessions[-1].distance_km for w in plan.weeks) <= GOALS["first_5k"][1]


# ---------------------------------------------------------------- routine


@pytest.mark.parametrize("days", [2, 3, 4, 5, 6])
@pytest.mark.parametrize("equipment", ["none", "dumbbells", "gym"])
def test_routine_fits_the_time_and_uses_the_equipment(days: int, equipment: str) -> None:
    routine = build_exercise_routine("general", days_per_week=days, minutes=40, equipment=equipment)  # type: ignore[arg-type]
    assert len(routine.days) == days == len(SPLITS[days])
    for day in routine.days:
        assert (
            day.exercises and day.estimated_minutes <= 40 + 5
        )  # one exercise of slack is the most it can exceed
        for ex in day.exercises:
            assert ex.name in CATALOG[ex.pattern][equipment]
    assert routine.assumptions and routine.rules and not [x for x in routine.notes if check_wording(x)]


def test_routine_reps_follow_the_goal_and_level() -> None:
    strength = build_exercise_routine("strength", level="intermediate", minutes=90)
    assert strength.days[0].exercises[0].sets == 4 and strength.days[0].exercises[0].reps == "5-8"
    endurance = build_exercise_routine("endurance", minutes=90)
    assert endurance.days[0].exercises[0].reps == "12-20" and endurance.days[0].exercises[0].rest_s == 45
    short = build_exercise_routine("general", minutes=20)
    assert len(short.days[0].exercises) < len(build_exercise_routine("general", minutes=90).days[0].exercises)


# ---------------------------------------------------------------- music hints


def test_running_music_follows_pace() -> None:
    fast = music_hint("running", pace_s_per_km=270.0)
    slow = music_hint("running", pace_s_per_km=420.0)
    assert fast.bpm_min > slow.bpm_min and fast.energy == "high" and slow.energy == "medium"
    assert fast.bpm_max - fast.bpm_min == 10 and not fast.assumptions
    unknown = music_hint("running")
    assert (unknown.bpm_min, unknown.bpm_max) == (160, 170) and unknown.assumptions
    for kind in ("walking", "cycling", "strength", "yoga", "swimming", "other"):
        hint = music_hint(kind, duration_min=60)
        assert hint.bpm_min < hint.bpm_max and hint.query and hint.basis
    assert music_hint("yoga").energy == "low"
