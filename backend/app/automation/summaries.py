"""Spoken summaries (en, hi, hinglish) for the automation tools. Names and counts come from the result."""

from __future__ import annotations

from app.automation.tools_io import ListOut, RunToolOut, SaveOut


def _pick(lang: str, en: str, hi: str, hinglish: str) -> str:
    return {"hi": hi, "hinglish": hinglish}.get(lang, en)


def list_summary(r: ListOut, lang: str) -> str:
    n = len(r.routines)
    if n == 0:
        return _pick(
            lang, "You have no routines yet.", "आपका कोई रूटीन अभी नहीं है।", "Aapka koi routine abhi nahi hai."
        )
    names = ", ".join(x.name for x in r.routines[:5])
    return _pick(
        lang,
        f"You have {n} routines: {names}.",
        f"आपके {n} रूटीन हैं: {names}।",
        f"Aapke {n} routines hain: {names}.",
    )


def run_summary(r: RunToolOut, lang: str) -> str:
    name, done, total = r.routine_name, len([s for s in r.step_log if s.status == "completed"]), r.steps_total
    if r.status == "completed":
        return _pick(
            lang,
            f"Ran {name}: all {total} steps are done.",
            f"{name} चल गया: सभी {total} स्टेप पूरे हुए।",
            f"{name} chal gaya: saare {total} steps poore hue.",
        )
    if r.status in ("awaiting_approval", "awaiting_device"):
        what_en = "your approval" if r.status == "awaiting_approval" else "your device"
        what_hi = "आपकी मंज़ूरी" if r.status == "awaiting_approval" else "आपके डिवाइस"
        what_hing = "aapki manzoori" if r.status == "awaiting_approval" else "aapke device"
        return _pick(
            lang,
            f"{name} paused after {done} of {total} steps; it is waiting for {what_en}.",
            f"{name} {total} में से {done} स्टेप के बाद रुका है; यह {what_hi} का इंतज़ार कर रहा है।",
            f"{name} {total} mein se {done} steps ke baad ruka hai; yeh {what_hing} ka intezaar kar raha hai.",
        )
    reason = r.error or r.status
    return _pick(
        lang,
        f"{name} stopped after {done} of {total} steps ({reason}).",
        f"{name} {total} में से {done} स्टेप के बाद रुक गया ({reason})।",
        f"{name} {total} mein se {done} steps ke baad ruk gaya ({reason}).",
    )


def save_summary(r: SaveOut, lang: str) -> str:
    n, name = len(r.routine.steps), r.routine.name
    if r.routine.trigger.kind != "manual":
        sched = {
            "daily": r.routine.trigger.time or "",
            "weekly": r.routine.trigger.time or "",
            "interval": str(r.routine.trigger.every_minutes),
        }[r.routine.trigger.kind]
        return _pick(
            lang,
            f"Saved {name} with {n} steps on a {r.routine.trigger.kind} schedule ({sched}).",
            f"{name} {n} स्टेप के साथ सेव हुआ, शेड्यूल: {r.routine.trigger.kind} ({sched})।",
            f"{name} {n} steps ke saath save hua, schedule: {r.routine.trigger.kind} ({sched}).",
        )
    return _pick(
        lang,
        f"Saved {name} with {n} steps; you run it by asking.",
        f"{name} {n} स्टेप के साथ सेव हुआ; आप इसे कहकर चलाते हैं।",
        f"{name} {n} steps ke saath save hua; aap ise bolkar chalate hain.",
    )
