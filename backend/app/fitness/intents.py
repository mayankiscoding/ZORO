"""Fitness intents for the local router: keywords in en / hi / hinglish and slot extraction.

One classifier decides which fitness intent an utterance is (most specific first), and each
`IntentSpec.extract` answers only for its own intent, so two fitness intents never both claim a
sentence. No model is involved.
"""

from __future__ import annotations

import re
import string
from collections.abc import Callable, Sequence
from datetime import date, timedelta
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.core.types import AgentId
from app.fitness.keywords import ANY_KW, GOAL_WORDS, KW, METRIC_WORDS, ORDER, WEEKLY_PAIR
from app.tools.intents import IntentContext, IntentSpec

_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")


_PUNCT = str.maketrans({c: " " for c in string.punctuation.replace(".", "") + "।॥…“”‘’"})


def _norm(text: str) -> str:
    """Lower-case, Devanagari digits to ASCII, punctuation to spaces (combining marks are kept)."""
    return " " + re.sub(r"\s+", " ", text.lower().translate(_DIGITS).translate(_PUNCT)).strip() + " "


def _has(text: str, words: Sequence[str]) -> bool:
    """ASCII phrases match on word boundaries; Devanagari phrases match as substrings."""
    return any(
        re.search(rf"(?<![a-z0-9]){re.escape(w)}(?![a-z0-9])", text) if w.isascii() else w in text
        for w in words
    )


def classify(utterance: str) -> str | None:
    text = _norm(utterance)
    for group in ORDER:
        if _has(text, ANY_KW[group]):
            return group
    if any(_has(text, a) and _has(text, b) for a, b in WEEKLY_PAIR):
        return "weekly"
    return None


_N_DAYS = re.compile(r"(?:last|past|pichhle|pichle|पिछले)\s+(\d{1,3})\s+(?:days|day|din|दिन)")


def _yesterday(text: str) -> bool:
    return _has(text, ("yesterday", "kal", "कल", "beete kal", "बीते कल"))


def _day_before(text: str) -> bool:
    return _has(text, ("day before yesterday", "parso", "परसों", "परसो"))


def _num(text: str, pattern: str) -> int | None:
    m = re.search(pattern, text)
    return int(m.group(1)) if m else None


Slots = Callable[[str, IntentContext], dict[str, Any]]
Extract = Callable[[str, IntentContext], dict[str, Any] | None]


def _guard(group: str) -> Callable[[Slots], Extract]:
    """The extractor only answers when the classifier says the utterance belongs to `group`."""

    def wrap(fn: Slots) -> Extract:
        def run(utterance: str, ctx: IntentContext) -> dict[str, Any] | None:
            return fn(_norm(utterance), ctx) if classify(utterance) == group else None

        return run

    return wrap


def _today(ctx: IntentContext) -> date:
    try:
        return ctx.now.astimezone(ZoneInfo(ctx.timezone)).date()
    except (ZoneInfoNotFoundError, ValueError):
        return ctx.now.date()


@_guard("daily")
def _daily(text: str, ctx: IntentContext) -> dict[str, Any]:
    today = _today(ctx)
    if _day_before(text):
        return {"date": (today - timedelta(days=2)).isoformat()}
    if _yesterday(text):
        return {"date": (today - timedelta(days=1)).isoformat()}
    return {}


@_guard("weekly")
def _weekly(text: str, ctx: IntentContext) -> dict[str, Any]:
    return {}


@_guard("trend")
def _trend(text: str, ctx: IntentContext) -> dict[str, Any]:
    metric = next((name for name, words in METRIC_WORDS if _has(text, words)), "steps")
    slots: dict[str, Any] = {"metric": metric}
    if (n := _num(text, _N_DAYS.pattern)) is not None:
        slots["days"] = min(max(n, 7), 180)
    elif _has(text, ("month", "mahine", "महीने", "mahina", "महीना")):
        slots["days"] = 30
    return slots


@_guard("running")
def _running(text: str, ctx: IntentContext) -> dict[str, Any]:
    n = _num(text, _N_DAYS.pattern)
    return {"days": min(max(n, 14), 365)} if n is not None else {}


@_guard("records")
def _records(text: str, ctx: IntentContext) -> dict[str, Any]:
    return {}


@_guard("consistency")
def _consistency(text: str, ctx: IntentContext) -> dict[str, Any]:
    n = _num(text, r"(?:last|past|pichhle|pichle|पिछले)\s+(\d{1,2})\s+(?:weeks|week|hafte|hafta|हफ़्ते|हफ्ते)")
    return {"weeks": min(max(n, 2), 26)} if n is not None else {}


@_guard("plan")
def _plan(text: str, ctx: IntentContext) -> dict[str, Any]:
    slots: dict[str, Any] = {}
    goal = next((g for g, words in GOAL_WORDS if _has(text, words)), None)
    if goal is None and re.search(r"(?<!\d)5\s*k(?!\w)", text):
        goal = "5k"
    if goal is None and re.search(r"(?<!\d)10\s*k(?!\w)", text):
        goal = "10k"
    if goal:
        slots["goal"] = goal
    if (
        (n := _num(text, r"(\d)\s*(?:days|day|din)\s*(?:a|per|ek|every)?\s*(?:week|hafte|hafta|हफ़्ते)?"))
        and 2 <= n <= 6
    ) or ((n := _num(text, r"(?:hafte mein|हफ़्ते में|हफ्ते में)\s*(\d)\s*(?:din|दिन)")) and 2 <= n <= 6):
        slots["days_per_week"] = n
    if (n := _num(text, r"(\d{1,2})\s*(?:weeks|week|hafte|हफ़्ते|हफ्ते)")) and 4 <= n <= 20:
        slots["weeks"] = n
    km = re.search(
        r"(\d{1,3}(?:\.\d)?)\s*(?:km|kms|kilometres|kilometers|किमी)\s*(?:a|per|ek|every)?\s*(?:week|hafte|hafta|हफ़्ते)",
        text,
    )
    if km:
        slots["current_weekly_km"] = float(km.group(1))
    return slots


@_guard("routine")
def _routine(text: str, ctx: IntentContext) -> dict[str, Any]:
    slots: dict[str, Any] = {}
    if _has(text, ("dumbbell", "dumbbells", "डंबल")):
        slots["equipment"] = "dumbbells"
    elif _has(text, ("gym", "जिम", "barbell")) and not _has(
        text, ("gym routine", "gym plan", "gym ka plan", "जिम रूटीन")
    ):
        slots["equipment"] = "gym"
    elif _has(text, ("no equipment", "bodyweight", "at home", "ghar par", "ghar pe", "घर पर", "बिना सामान")):
        slots["equipment"] = "none"
    if _has(text, ("strength", "muscle", "ताक़त", "ताकत", "taqat", "taakat")):
        slots["goal"] = "strength"
    elif _has(text, ("endurance", "stamina", "सहनशक्ति")):
        slots["goal"] = "endurance"
    if (n := _num(text, r"(\d)\s*(?:days|day|din|दिन)")) and 2 <= n <= 6:
        slots["days_per_week"] = n
    if (n := _num(text, r"(\d{2,3})\s*(?:minutes|minute|min|mins|मिनट)")) and 20 <= n <= 120:
        slots["minutes"] = n
    return slots


@_guard("music")
def _music(text: str, ctx: IntentContext) -> dict[str, Any]:
    kinds = (
        ("running", ("run", "running", "daud", "दौड़", "रनिंग", "jog")),
        ("walking", ("walk", "walking", "paidal", "पैदल", "सैर")),
        ("cycling", ("cycling", "bike", "cycle", "साइकिल")),
        ("strength", ("gym", "weights", "strength", "जिम", "वेट")),
        ("yoga", ("yoga", "योग", "योगा")),
        ("swimming", ("swim", "swimming", "तैराकी")),
    )
    kind = next((k for k, words in kinds if _has(text, words)), "other")
    return {"workout_type": kind}


def build_intents() -> list[IntentSpec]:
    fit = AgentId.FITNESS

    group_of = {
        "fitness.daily_summary": "daily",
        "fitness.weekly_comparison": "weekly",
        "fitness.trends": "trend",
        "fitness.running_progress": "running",
        "fitness.personal_records": "records",
        "fitness.consistency": "consistency",
        "fitness.build_running_plan": "plan",
        "fitness.build_routine": "routine",
        "fitness.music_hint": "music",
    }

    def spec(name: str, tool: str, fn: Extract, examples: Sequence[str], priority: int = 5) -> IntentSpec:
        group = group_of[name]
        return IntentSpec(
            name=name,
            agent=fit,
            tool=tool,
            keywords=KW[group],
            extract=fn,
            examples=examples,
            priority=priority,
        )

    return [
        spec(
            "fitness.daily_summary",
            "fitness.daily_summary",
            _daily,
            ("how many steps today", "aaj kitne kadam chale", "कल कितने कदम चले"),
            4,
        ),
        spec(
            "fitness.weekly_comparison",
            "fitness.weekly_comparison",
            _weekly,
            ("compare this week with last week", "pichhle hafte se tulna karo", "पिछले हफ़्ते से तुलना करो"),
            6,
        ),
        spec(
            "fitness.trends",
            "fitness.trends",
            _trend,
            ("sleep trend last 30 days", "mere kadam ka trend", "नींद का ट्रेंड"),
            6,
        ),
        spec(
            "fitness.running_progress",
            "fitness.running_progress",
            _running,
            ("how is my running progress", "meri running kaisi chal rahi hai", "मेरी रनिंग की प्रगति"),
            5,
        ),
        spec(
            "fitness.personal_records",
            "fitness.personal_records",
            _records,
            ("what are my personal bests", "meri sabse lambi run", "मेरे रिकॉर्ड बताओ"),
            6,
        ),
        spec(
            "fitness.consistency",
            "fitness.consistency",
            _consistency,
            ("what is my workout streak", "kitne din workout kiya", "मेरी स्ट्रीक कितनी है"),
            5,
        ),
        spec(
            "fitness.build_running_plan",
            "fitness.build_running_plan",
            _plan,
            ("build me a 10k plan", "5k ka running plan banao", "मेरे लिए रनिंग प्लान बनाओ"),
            8,
        ),
        spec(
            "fitness.build_routine",
            "fitness.build_routine",
            _routine,
            ("make me a 4 day gym routine", "workout plan banao dumbbell ke saath", "जिम रूटीन बनाओ"),
            8,
        ),
        spec(
            "fitness.music_hint",
            "fitness.music_hint",
            _music,
            ("music for my run", "run ke liye gaane", "वर्कआउट के लिए गाने"),
            8,
        ),
    ]
