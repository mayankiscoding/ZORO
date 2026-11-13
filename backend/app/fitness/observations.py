"""Recovery-related observations from resting heart rate, sleep and training load.

Plain rules on the owner's own numbers, worded as fitness information (never a reading of health
status). Each observation is a code plus numbers; `render_observation` turns it into a sentence in
en / hi / hinglish and runs the wording check, so a template that ever drifted into medical language
would be dropped instead of spoken.
"""

from __future__ import annotations

from datetime import date, timedelta

from pydantic import BaseModel, ConfigDict

from app.fitness.records import DayRec
from app.fitness.stats import mean
from app.fitness.wording import check_wording

RHR_RAISED_BPM = 5.0
RHR_LOWER_BPM = 3.0
SHORT_SLEEP_MIN = 360.0
LOAD_UP_RATIO = 1.3
MIN_BASELINE_POINTS = 7


class Observation(BaseModel):
    model_config = ConfigDict(extra="ignore")

    code: str
    values: dict[str, float] = {}


# code -> (en, hi, hinglish), each formatted with the observation's values.
TEMPLATES: dict[str, tuple[str, str, str]] = {
    "rhr_above_baseline": (
        "Your resting heart rate over the last {days:.0f} days is {delta:.0f} bpm above your recent average. "
        "That often goes with a hard training week or short sleep; an easy day is a common choice.",
        "पिछले {days:.0f} दिनों में आपकी रेस्टिंग हार्ट रेट हाल के औसत से {delta:.0f} bpm ऊपर है। "
        "यह अक्सर भारी ट्रेनिंग हफ़्ते या कम नींद के साथ दिखता है; हल्का दिन रखना आम तरीका है।",
        "Pichhle {days:.0f} din ki resting heart rate aapke recent average se {delta:.0f} bpm upar hai. "
        "Yeh aksar bhaari training week ya kam neend ke saath dikhta hai; halka din rakhna aam tareeka hai.",
    ),
    "rhr_below_baseline": (
        "Your resting heart rate over the last {days:.0f} days is {delta:.0f} bpm below your recent average, "
        "which often goes with good recovery between sessions.",
        "पिछले {days:.0f} दिनों में आपकी रेस्टिंग हार्ट रेट हाल के औसत से {delta:.0f} bpm नीचे है, "
        "जो अक्सर सेशन के बीच अच्छी रिकवरी के साथ दिखता है।",
        "Pichhle {days:.0f} din ki resting heart rate aapke recent average se {delta:.0f} bpm neeche hai, "
        "jo aksar sessions ke beech achhi recovery ke saath dikhta hai.",
    ),
    "short_sleep_run": (
        "You logged under {hours:.0f} hours of sleep on each of the last {nights:.0f} nights; "
        "shorter sleep usually makes hard sessions feel harder.",
        "पिछली {nights:.0f} रातों में हर रात {hours:.0f} घंटे से कम नींद दर्ज हुई; "
        "कम नींद में कठिन सेशन आमतौर पर ज़्यादा भारी लगते हैं।",
        "Pichhli {nights:.0f} raaton mein har raat {hours:.0f} ghante se kam neend darj hui; "
        "kam neend mein mushkil sessions aamtaur par zyada bhaari lagte hain.",
    ),
    "load_up": (
        "Your exercise minutes this week are {ratio_pct:.0f} percent of your recent weekly average; "
        "a lighter day or two is a common way to absorb a jump like that.",
        "इस हफ़्ते आपके एक्सरसाइज़ मिनट हाल के साप्ताहिक औसत का {ratio_pct:.0f} प्रतिशत हैं; "
        "ऐसी उछाल के बाद एक-दो हल्के दिन रखना आम तरीका है।",
        "Is hafte aapke exercise minutes recent weekly average ka {ratio_pct:.0f} percent hain; "
        "aisi uchhaal ke baad ek-do halke din rakhna aam tareeka hai.",
    ),
}
_LANG_INDEX = {"en": 0, "hi": 1, "hinglish": 2}


def render_observation(obs: Observation, lang: str) -> str | None:
    """The observation as one sentence, or None when the template is unknown or fails the wording check."""
    template = TEMPLATES.get(obs.code)
    if template is None:
        return None
    try:
        text = template[_LANG_INDEX.get(lang, 0)].format(**obs.values)
    except (KeyError, ValueError):
        return None
    return None if check_wording(text) else text


def recovery_observations(days: list[DayRec], end: date) -> list[Observation]:
    """Rules over the days up to `end`. Each needs enough data; with too little it says nothing."""
    out: list[Observation] = []
    by_date = {d.date: d for d in days}

    # Resting heart rate: last 3 days against the 28 days before them.
    recent_rhr = [
        v for i in range(3) if (d := by_date.get(end - timedelta(days=i))) and (v := d.resting_heart_rate_bpm)
    ]
    base_rhr = [
        v
        for i in range(3, 31)
        if (d := by_date.get(end - timedelta(days=i))) and (v := d.resting_heart_rate_bpm)
    ]
    if len(recent_rhr) >= 2 and len(base_rhr) >= MIN_BASELINE_POINTS:
        delta = (mean(recent_rhr) or 0) - (mean(base_rhr) or 0)
        if delta >= RHR_RAISED_BPM:
            out.append(Observation(code="rhr_above_baseline", values={"days": 3, "delta": round(delta)}))
        elif delta <= -RHR_LOWER_BPM:
            out.append(Observation(code="rhr_below_baseline", values={"days": 3, "delta": round(-delta)}))

    # Sleep: three nights in a row under 6 hours.
    nights = [by_date.get(end - timedelta(days=i)) for i in range(3)]
    if all(n is not None and n.sleep_minutes is not None for n in nights) and all(
        (n.sleep_minutes or 0) < SHORT_SLEEP_MIN for n in nights if n is not None
    ):
        out.append(Observation(code="short_sleep_run", values={"hours": SHORT_SLEEP_MIN / 60, "nights": 3}))

    # Training load: exercise minutes this week against the average of the 4 weeks before.
    this_week = [
        by_date[end - timedelta(days=i)].exercise_minutes
        for i in range(7)
        if end - timedelta(days=i) in by_date
    ]
    prior = [
        by_date[end - timedelta(days=i)].exercise_minutes
        for i in range(7, 35)
        if end - timedelta(days=i) in by_date
    ]
    this_vals = [v for v in this_week if v is not None]
    prior_vals = [v for v in prior if v is not None]
    if len(this_vals) >= 3 and len(prior_vals) >= 14:
        weekly_prior = sum(prior_vals) / len(prior_vals) * 7
        if weekly_prior > 0 and sum(this_vals) / weekly_prior >= LOAD_UP_RATIO:
            out.append(
                Observation(code="load_up", values={"ratio_pct": round(sum(this_vals) / weekly_prior * 100)})
            )
    return out
