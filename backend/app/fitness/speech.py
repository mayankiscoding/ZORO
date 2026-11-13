"""Shared pieces of the spoken summaries: language picker, freshness and source phrases, the
"unavailable" sentences, metric names."""

from __future__ import annotations

from app.fitness.observations import render_observation
from app.fitness.results import Sourced, TrendResult


def pick(lang: str, en: str, hi: str, hinglish: str) -> str:
    return {"hi": hi, "hinglish": hinglish}.get(lang, en)


def num(value: float | int) -> str:
    return f"{value:g}"


UNITS = {
    "minutes": ("minute", "minutes", "मिनट", "minute"),
    "hours": ("hour", "hours", "घंटे", "ghante"),
    "days": ("day", "days", "दिन", "din"),
}


def freshness_text(r: Sourced, lang: str) -> str:
    f = r.freshness
    if f.last_synced_at is None or f.age_value is None or f.age_unit is None:
        return pick(lang, "never synced", "अभी तक सिंक नहीं हुआ", "abhi tak sync nahi hua")
    one, many, hi, hing = UNITS[f.age_unit]
    n = f.age_value
    if n == 0 and f.age_unit == "minutes":
        return pick(lang, "synced just now", "अभी सिंक हुआ", "abhi sync hua")
    return pick(
        lang,
        f"synced {n} {one if n == 1 else many} ago",
        f"{n} {hi} पहले सिंक हुआ",
        f"{n} {hing} pehle sync hua",
    )


def source_text(r: Sourced, lang: str) -> str:
    name = "Apple Health" + (" + Strava" if not r.external_model_allowed else "")
    if r.data_source.startswith(("Plan rules", "Routine rules", "Tempo rules")):
        name = pick(
            lang, "your inputs and ZORO's rules", "आपके इनपुट और ZORO के नियम", "aapke inputs aur ZORO ke rules"
        )
        return pick(lang, f"based on {name}", f"{name} पर आधारित", f"{name} par based")
    return pick(
        lang,
        f"{name}, {freshness_text(r, lang)}",
        f"{name}, {freshness_text(r, lang)}",
        f"{name}, {freshness_text(r, lang)}",
    )


def wrap(r: Sourced, lang: str, body: str) -> str:
    """`body` ends without a full stop; the source clause goes in brackets, then the stop."""
    stop = "।" if lang == "hi" else "."
    return f"{body} ({source_text(r, lang)}){stop}"


def with_observation(r: Sourced, lang: str, text: str) -> str:
    """Add the first recovery observation (already wording-checked) after the main sentence."""
    for obs in r.observations:
        if extra := render_observation(obs, lang):
            return f"{text} {extra}"
    return text


def unavailable(r: Sourced, lang: str) -> str:
    reason = r.reason or "not_enough_data"
    lines = {
        "never_synced": (
            "No fitness data has been synced from your iPhone yet; open ZORO on your iPhone and allow Health access",
            "आपके iPhone से अभी कोई फ़िटनेस डेटा सिंक नहीं हुआ; iPhone पर ZORO खोलकर Health की अनुमति दें",
            "Aapke iPhone se abhi koi fitness data sync nahi hua; iPhone par ZORO kholkar Health ki anumati dein",
        ),
        "no_data_for_date": (
            "There is no synced Apple Health data for that day",
            "उस दिन का कोई सिंक किया हुआ Apple Health डेटा नहीं है",
            "Us din ka koi synced Apple Health data nahi hai",
        ),
        "no_running_data": (
            "I found no running workouts in the synced data",
            "सिंक किए गए डेटा में कोई रनिंग वर्कआउट नहीं मिला",
            "Synced data mein koi running workout nahi mila",
        ),
        "no_data_in_window": (
            "There is no synced data in that period",
            "उस अवधि का कोई सिंक किया हुआ डेटा नहीं है",
            "Us avadhi ka koi synced data nahi hai",
        ),
    }
    en, hi, hing = lines.get(
        reason,
        (
            "There is not enough synced data for a reliable answer yet",
            "भरोसेमंद जवाब के लिए अभी पर्याप्त सिंक किया हुआ डेटा नहीं है",
            "Bharosemand jawab ke liye abhi paryapt synced data nahi hai",
        ),
    )
    if isinstance(r, TrendResult) and reason == "not_enough_data":
        n, need = r.points_used, r.min_points
        en = f"Only {n} days of {r.metric.replace('_', ' ')} data; at least {need} are needed for a trend"
        hi = f"{r.metric.replace('_', ' ')} का सिर्फ़ {n} दिन का डेटा है; ट्रेंड के लिए कम से कम {need} चाहिए"
        hing = f"{r.metric.replace('_', ' ')} ka sirf {n} din ka data hai; trend ke liye kam se kam {need} chahiye"
    return wrap(r, lang, pick(lang, en, hi, hing))


METRIC_NAMES = {
    "steps": ("steps", "कदम", "kadam"),
    "exercise_minutes": ("exercise minutes", "एक्सरसाइज़ मिनट", "exercise minutes"),
    "active_energy_kcal": ("active calories", "एक्टिव कैलोरी", "active calories"),
    "sleep_hours": ("sleep hours", "नींद के घंटे", "neend ke ghante"),
    "resting_heart_rate_bpm": ("resting heart rate", "रेस्टिंग हार्ट रेट", "resting heart rate"),
    "body_mass_kg": ("body weight", "शरीर का वज़न", "sharir ka wazan"),
    "distance_km": ("walking and running distance", "पैदल और दौड़ की दूरी", "paidal aur daud ki doori"),
}


def metric_name(name: str, lang: str) -> str:
    en, hi, hing = METRIC_NAMES.get(name, (name.replace("_", " "),) * 3)
    return pick(lang, en, hi, hing)
