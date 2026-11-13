"""Spoken one-sentence summaries (en, hi in Devanagari, hinglish romanised) and the `fitness_summary` card.

Every figure comes from the tool result, and every answer names its source and how fresh it is, in
the same sentence. Nothing is rounded into a different number than the result holds.
"""

from __future__ import annotations

from app.fitness.cards import card
from app.fitness.plans import RunningPlan
from app.fitness.results import (
    Consistency,
    DailySummary,
    PersonalRecords,
    RunningProgress,
    TrendResult,
    WeeklyComparison,
)
from app.fitness.routines import ExerciseRoutine, MusicHint
from app.fitness.service import MusicHintOut, RoutineOut, RunningPlanOut
from app.fitness.speech import (
    metric_name,
    num,
    pick,
    unavailable,
    with_observation,
    wrap,
)


def daily(r: DailySummary, lang: str) -> str:
    if not r.available:
        return unavailable(r, lang)
    en: list[str] = []
    hi: list[str] = []
    hing: list[str] = []
    if r.steps is not None:
        en.append(f"{r.steps} steps")
        hi.append(f"{r.steps} कदम")
        hing.append(f"{r.steps} kadam")
    if r.distance_km is not None:
        en.append(f"{num(r.distance_km)} km on foot")
        hi.append(f"{num(r.distance_km)} किमी पैदल")
        hing.append(f"{num(r.distance_km)} km paidal")
    if r.exercise_minutes is not None:
        en.append(f"{r.exercise_minutes} exercise minutes")
        hi.append(f"{r.exercise_minutes} मिनट एक्सरसाइज़")
        hing.append(f"{r.exercise_minutes} minute exercise")
    if r.sleep_hours is not None:
        en.append(f"{num(r.sleep_hours)} hours of sleep")
        hi.append(f"{num(r.sleep_hours)} घंटे नींद")
        hing.append(f"{num(r.sleep_hours)} ghante neend")
    if not en and r.active_energy_kcal is not None:
        en.append(f"{r.active_energy_kcal} active calories")
        hi.append(f"{r.active_energy_kcal} एक्टिव कैलोरी")
        hing.append(f"{r.active_energy_kcal} active calories")
    if not en:
        return unavailable(r.model_copy(update={"reason": "no_data_for_date"}), lang)
    day = r.date.isoformat()
    return with_observation(
        r,
        lang,
        wrap(
            r,
            lang,
            pick(
                lang,
                f"On {day} you had {', '.join(en[:4])}",
                f"{day} को आपके {', '.join(hi[:4])} रहे",
                f"{day} ko aapke {', '.join(hing[:4])} rahe",
            ),
        ),
    )


def weekly(r: WeeklyComparison, lang: str) -> str:
    return with_observation(r, lang, _weekly(r, lang))


def _weekly(r: WeeklyComparison, lang: str) -> str:
    if not r.available:
        return unavailable(r, lang)
    m = next(
        (x for x in r.metrics if x.enough_data and x.change_pct is not None and x.metric == "steps"), None
    ) or next((x for x in r.metrics if x.enough_data and x.change_pct is not None), None)
    wc, wp = r.workouts_current, r.workouts_previous
    end = r.current_end.isoformat() if r.current_end else ""
    if m is None or m.change_pct is None or m.current_avg is None:
        return wrap(
            r,
            lang,
            pick(
                lang,
                f"In the 7 days to {end} you did {wc} workouts against {wp} in the 7 days before",
                f"{end} तक के 7 दिनों में {wc} वर्कआउट हुए, उससे पहले के 7 दिनों में {wp}",
                f"{end} tak ke 7 din mein {wc} workouts hue, usse pehle ke 7 din mein {wp}",
            ),
        )
    pct = abs(m.change_pct)
    name = metric_name(m.metric, lang)
    up = m.change_pct > 0
    direction = pick(lang, "up" if up else "down", "ज़्यादा" if up else "कम", "zyada" if up else "kam")
    if m.change_pct == 0:
        direction = pick(lang, "unchanged", "बराबर", "barabar")
    return wrap(
        r,
        lang,
        pick(
            lang,
            f"In the 7 days to {end} your {name} averaged {num(m.current_avg)} a day, {num(pct)} percent {direction} than the 7 days before, with {wc} workouts against {wp}"
            if m.change_pct != 0
            else f"In the 7 days to {end} your {name} averaged {num(m.current_avg)} a day, unchanged from the 7 days before, with {wc} workouts against {wp}",
            f"{end} तक के 7 दिनों में आपके {name} का औसत रोज़ {num(m.current_avg)} रहा, पिछले 7 दिनों से {num(pct)} प्रतिशत {direction}, और {wc} वर्कआउट बनाम {wp}",
            f"{end} tak ke 7 din mein aapke {name} ka average roz {num(m.current_avg)} raha, pichhle 7 din se {num(pct)} percent {direction}, aur {wc} workouts banam {wp}",
        ),
    )


def trend(r: TrendResult, lang: str) -> str:
    if not r.available or r.slope_per_week is None or r.mean is None:
        return unavailable(r, lang)
    name, n = metric_name(r.metric, lang), r.points_used
    if r.direction == "steady":
        return wrap(
            r,
            lang,
            pick(
                lang,
                f"Your {name} is steady, averaging {num(r.mean)} {r.unit}, across {n} days of data",
                f"आपके {name} स्थिर हैं, औसत {num(r.mean)} {r.unit}, {n} दिनों के डेटा पर",
                f"Aapke {name} sthir hain, average {num(r.mean)} {r.unit}, {n} din ke data par",
            ),
        )
    up = r.direction == "up"
    s = num(abs(r.slope_per_week))
    return wrap(
        r,
        lang,
        pick(
            lang,
            f"Your {name} is trending {'up' if up else 'down'} by {s} {r.unit} a week, across {n} days of data",
            f"आपके {name} हर हफ़्ते {s} {r.unit} {'बढ़' if up else 'घट'} रहे हैं, {n} दिनों के डेटा पर",
            f"Aapke {name} har hafte {s} {r.unit} {'badh' if up else 'ghat'} rahe hain, {n} din ke data par",
        ),
    )


def running(r: RunningProgress, lang: str) -> str:
    if not r.available or r.runs == 0:
        return unavailable(r, lang)
    pace = r.avg_pace_text
    if r.direction == "insufficient_data" or r.pace_change_s_per_km_per_week is None or pace is None:
        tail_en = f"; at least {r.min_runs} runs with pace are needed to judge a trend"
        tail_hi = f"; ट्रेंड के लिए पेस वाली कम से कम {r.min_runs} दौड़ें चाहिए"
        tail_hing = f"; trend ke liye pace wali kam se kam {r.min_runs} runs chahiye"
        return wrap(
            r,
            lang,
            pick(
                lang,
                f"You have {r.runs} runs covering {num(r.total_km)} km{tail_en}",
                f"आपकी {r.runs} दौड़ों में {num(r.total_km)} किमी हुए{tail_hi}",
                f"Aapki {r.runs} runs mein {num(r.total_km)} km hue{tail_hing}",
            ),
        )
    change = num(abs(r.pace_change_s_per_km_per_week))
    if r.direction == "steady":
        en, hi, hing = "your pace is steady", "आपकी रफ़्तार स्थिर है", "aapki raftaar sthir hai"
    elif r.direction == "faster":
        en, hi, hing = (
            f"you are getting faster by {change} seconds per km each week",
            f"आप हर हफ़्ते {change} सेकंड प्रति किमी तेज़ हो रहे हैं",
            f"aap har hafte {change} second per km tez ho rahe hain",
        )
    else:
        en, hi, hing = (
            f"you are getting slower by {change} seconds per km each week",
            f"आप हर हफ़्ते {change} सेकंड प्रति किमी धीमे हो रहे हैं",
            f"aap har hafte {change} second per km dheemey ho rahe hain",
        )
    return wrap(
        r,
        lang,
        pick(
            lang,
            f"Over {r.runs} runs and {num(r.total_km)} km your average pace is {pace} per km and {en}",
            f"{r.runs} दौड़ों और {num(r.total_km)} किमी में आपकी औसत रफ़्तार {pace} प्रति किमी है और {hi}",
            f"{r.runs} runs aur {num(r.total_km)} km mein aapki average raftaar {pace} per km hai aur {hing}",
        ),
    )


def records(r: PersonalRecords, lang: str) -> str:
    if not r.available or not r.records:
        return unavailable(r, lang)
    by = {x.kind: x for x in r.records}
    en: list[str] = []
    hi: list[str] = []
    hing: list[str] = []
    if x := by.get("longest_run"):
        en.append(f"longest run {x.display} km on {x.on}")
        hi.append(f"सबसे लंबी दौड़ {x.display} किमी, {x.on} को")
        hing.append(f"sabse lambi run {x.display} km, {x.on} ko")
    if x := by.get("fastest_pace_run"):
        en.append(f"fastest run pace {x.display} per km")
        hi.append(f"सबसे तेज़ रफ़्तार {x.display} प्रति किमी")
        hing.append(f"sabse tez raftaar {x.display} per km")
    if x := by.get("most_steps_day"):
        en.append(f"most steps in a day {x.display}")
        hi.append(f"एक दिन में सबसे ज़्यादा कदम {x.display}")
        hing.append(f"ek din mein sabse zyada kadam {x.display}")
    if not en:
        x = r.records[0]
        en.append(f"{x.kind.replace('_', ' ')} {x.display} {x.unit}")
        hi.append(f"{x.kind.replace('_', ' ')} {x.display} {x.unit}")
        hing.append(f"{x.kind.replace('_', ' ')} {x.display} {x.unit}")
    return wrap(
        r,
        lang,
        pick(
            lang,
            "Your records: " + ", ".join(en),
            "आपके रिकॉर्ड: " + ", ".join(hi),
            "Aapke records: " + ", ".join(hing),
        ),
    )


def consistency(r: Consistency, lang: str) -> str:
    if not r.available:
        return unavailable(r, lang)
    avg = r.avg_sessions_per_week
    a, d, cs, ls = r.active_days, r.days_with_data, r.current_streak_days, r.longest_streak_days
    tail_en = f", averaging {num(avg)} sessions a week" if avg is not None else ""
    tail_hi = f", औसत {num(avg)} सेशन प्रति हफ़्ता" if avg is not None else ""
    tail_hing = f", average {num(avg)} sessions per hafta" if avg is not None else ""
    return wrap(
        r,
        lang,
        pick(
            lang,
            f"You were active on {a} of {d} days with data, a current streak of {cs} days and a longest of {ls}{tail_en}",
            f"डेटा वाले {d} दिनों में से आप {a} दिन सक्रिय रहे, मौजूदा स्ट्रीक {cs} दिन और सबसे लंबी {ls} दिन{tail_hi}",
            f"Data wale {d} dinon mein se aap {a} din active rahe, current streak {cs} din aur sabse lambi {ls} din{tail_hing}",
        ),
    )


GOAL_NAMES = {
    "first_5k": ("first 5K", "पहली 5K", "pehli 5K"),
    "5k": ("5K", "5K", "5K"),
    "10k": ("10K", "10K", "10K"),
    "half_marathon": ("half marathon", "हाफ मैराथन", "half marathon"),
}


def plan(r: RunningPlanOut, lang: str) -> str:
    p: RunningPlan | None = r.plan
    if p is None or not p.weeks:
        return unavailable(r, lang)
    name = pick(lang, *GOAL_NAMES[p.goal])
    n, start, peak, d = (
        len(p.weeks),
        num(p.start_weekly_km),
        num(max(w.total_km for w in p.weeks)),
        p.days_per_week,
    )
    note_en = " (starting volume assumed)" if p.start_basis == "assumed" else ""
    note_hi = " (शुरुआती दूरी अनुमानित)" if p.start_basis == "assumed" else ""
    note_hing = " (starting volume anumaanit)" if p.start_basis == "assumed" else ""
    return wrap(
        r,
        lang,
        pick(
            lang,
            f"Your {n}-week {name} plan runs {d} days a week, from {start} km to a peak of {peak} km{note_en}",
            f"आपकी {n} हफ़्ते की {name} योजना हफ़्ते में {d} दिन है, {start} किमी से शुरू होकर {peak} किमी तक{note_hi}",
            f"Aapki {n} hafte ki {name} plan hafte mein {d} din hai, {start} km se shuru hokar {peak} km tak{note_hing}",
        ),
    )


def routine(r: RoutineOut, lang: str) -> str:
    x: ExerciseRoutine | None = r.routine
    if x is None:
        return unavailable(r, lang)
    d, m = len(x.days), x.minutes_per_session
    return wrap(
        r,
        lang,
        pick(
            lang,
            f"Your {d}-day routine takes about {m} minutes a session",
            f"आपका {d} दिन का रूटीन हर सेशन लगभग {m} मिनट का है",
            f"Aapka {d} din ka routine har session lagbhag {m} minute ka hai",
        ),
    )


def music(r: MusicHintOut, lang: str) -> str:
    h: MusicHint | None = r.hint
    if h is None:
        return unavailable(r, lang)
    lo, hi_, kind = h.bpm_min, h.bpm_max, h.workout_type
    return wrap(
        r,
        lang,
        pick(
            lang,
            f"For {kind}, try music at {lo} to {hi_} beats a minute with {h.energy} energy",
            f"{kind} के लिए {lo} से {hi_} बीट प्रति मिनट का संगीत आज़माएँ, {h.energy} एनर्जी के साथ",
            f"{kind} ke liye {lo} se {hi_} beats per minute ka music try karein, {h.energy} energy ke saath",
        ),
    )


__all__ = [
    "card",
    "consistency",
    "daily",
    "music",
    "plan",
    "records",
    "routine",
    "running",
    "trend",
    "weekly",
]
