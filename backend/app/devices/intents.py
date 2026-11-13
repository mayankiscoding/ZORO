"""Device intents with deterministic slot filling (English, Hindi, Hinglish).

Extractors return tool arguments. Keys starting with "_" are hints for the orchestrator and are
ignored by the tools' input models: `_target_platform` ("ios" | "macos", from "on my Mac" /
"phone par"), `_missing` (required slots not found), `_problem` (a `WhenError` code),
`_ambiguous` (AM/PM was guessed), `_assumptions` (e.g. "kal_means_tomorrow").
"""

from __future__ import annotations

import re
from collections.abc import Callable
from datetime import datetime, time, timedelta
from typing import Any

from app.core.types import AgentId
from app.devices.homeassistant import HomeAssistantConfig
from app.devices.parsing.lexicon import L, R, alt, norm
from app.devices.parsing.slots import (
    clean_title,
    extract_email,
    extract_phone,
    extract_repeat_days,
    extract_switch,
    extract_target,
    remove_spans,
)
from app.devices.parsing.when import When, WhenError, parse_duration, parse_when, zone
from app.tools.intents import IntentContext, IntentSpec

Slots = dict[str, Any]


def _has(text: str, words: tuple[str, ...]) -> bool:
    return re.search(rf"{L}{alt(words)}{R}", norm(text)) is not None


def _base(text: str) -> tuple[Slots, list[tuple[int, int]]]:
    platform, span = extract_target(text)
    return ({"_target_platform": platform.value} if platform else {}), ([span] if span else [])


def _when(text: str, ctx: IntentContext, slots: Slots, spans: list[tuple[int, int]]) -> When | None:
    """Parse the time; on success or failure the expression's spans are added to `spans`."""
    try:
        when = parse_when(text, ctx.now, ctx.timezone)
    except WhenError as exc:
        slots["_problem"] = exc.code
        spans += list(exc.spans)
        return None
    if when is not None:
        spans += list(when.spans)
        if when.ambiguous:
            slots["_ambiguous"] = True
        if when.assumptions:
            slots["_assumptions"] = list(when.assumptions)
    return when


_SUFFIX = ("karo", "kar do", "kardo", "dena", "de do", "lagao", "laga do", "lagana", "set karo", "करो", "कर दो",
           "देना", "लगाओ", "लगा दो", "सेट करो", "बनाओ", "बना दो")  # fmt: skip
_ASK = ("please", "can you", "could you", "for me", "zara", "ज़रा", "जरा")
_COMMON = (*_SUFFIX, *_ASK, "set", "create", "add", "make")

# ---------------------------------------------------------------- alarm


_ALARM = ("alarm", "alarms", "wake me", "wake me up", "jaga dena", "jaga do", "utha dena", "अलार्म", "जगा देना",
          "उठा देना")  # fmt: skip


def extract_alarm(text: str, ctx: IntentContext) -> Slots | None:
    if not _has(text, _ALARM):
        return None
    slots, spans = _base(text)
    days, day_spans = extract_repeat_days(text)
    when = _when(text, ctx, slots, spans)
    if when is None or not when.has_time:
        slots["_missing"] = ["time"]
    else:
        slots["time"] = when.hhmm
    if days:
        slots["repeat_days"] = days
    label = clean_title(text, _ALARM + _COMMON + ("an", "a", "up", "mujhe", "मुझे"), spans + day_spans)
    if label and len(label) <= 60:
        slots["label"] = label
    return slots


# ---------------------------------------------------------------- timer

_TIMER = ("timer", "countdown", "टाइमर")


def extract_timer(text: str, ctx: IntentContext) -> Slots | None:
    if not _has(text, _TIMER):
        return None
    slots, spans = _base(text)
    duration = parse_duration(text)
    if duration is None:
        slots["_missing"] = ["seconds"]
    else:
        slots["seconds"] = min(duration.seconds, 24 * 3600)
        spans += list(duration.spans)
    label = clean_title(text, _TIMER + _COMMON + ("start", "shuru", "शुरू", "a", "an"), spans)
    if label and len(label) <= 60:
        slots["label"] = label
    return slots


# ---------------------------------------------------------------- reminder

_REMIND = ("remind", "reminder", "yaad dila", "yaad dilana", "yaad dilao", "yaad dila do", "याद दिला",
           "याद दिलाना", "याद दिलाओ", "याद दिला देना", "रिमाइंडर")  # fmt: skip
_REMIND_STRIP = (*_REMIND, *_SUFFIX, *_ASK, "set a reminder", "set reminder", "create a reminder", "add a reminder",
                 "remind me", "mujhe", "मुझे", "ki yaad dilana", "ki yaad dila dena", "की याद दिलाना",
                 "की याद दिला देना", "ki yaad", "की याद", "dilana", "dila dena", "dila do", "दिलाना", "दिला देना",
                 "दिला दो")  # fmt: skip


def extract_reminder(text: str, ctx: IntentContext) -> Slots | None:
    if not _has(text, _REMIND):
        return None
    slots, spans = _base(text)
    when = _when(text, ctx, slots, spans)
    if when is not None and when.at > ctx.now:
        slots["due_at"] = when.at.isoformat()
    title = clean_title(text, _REMIND_STRIP, spans)
    if title:
        slots["title"] = title
    else:
        slots["_missing"] = ["title"]
    return slots


# ---------------------------------------------------------------- calendar

_NEXT_MEETING = ("next meeting", "next event", "next appointment", "agli meeting", "agla meeting",
                 "अगली मीटिंग", "अगला इवेंट", "on my calendar", "calendar mein kya", "my schedule",
                 "aaj ka schedule", "आज का शेड्यूल", "meetings today", "aaj ki meetings", "आज की मीटिंग",
                 "kal ki meetings", "कल की मीटिंग", "meetings tomorrow")  # fmt: skip
_TODAY = ("today", "aaj", "आज")
_TOMORROW = ("tomorrow", "kal", "कल")


def extract_next_meeting(text: str, ctx: IntentContext) -> Slots | None:
    if not _has(text, _NEXT_MEETING):
        return None
    slots, _ = _base(text)
    local_now = ctx.now.astimezone(zone(ctx.timezone))
    for words, offset in ((_TOMORROW, 1), (_TODAY, 0)):
        if _has(text, words):
            day = local_now.date() + timedelta(days=offset)
            start = local_now if offset == 0 else datetime.combine(day, time(0, 0), tzinfo=local_now.tzinfo)
            end = datetime.combine(day + timedelta(days=1), time(0, 0), tzinfo=local_now.tzinfo)
            slots.update({"from": start.isoformat(), "to": end.isoformat(), "limit": 10})
            return slots
    slots.update({"from": local_now.isoformat(), "limit": 1})
    return slots


_EVENT = ("calendar", "event", "meeting", "appointment", "कैलेंडर", "इवेंट", "मीटिंग", "अपॉइंटमेंट")
_CREATE = ("add", "create", "schedule", "book", "put", "set up", "rakh", "rakho", "rakh do", "fix karo", "daal do",
           "dal do", "जोड़", "जोड़ो", "जोड़ दो", "रख", "रखो", "रख दो", "बना दो", "डाल दो")  # fmt: skip
_EVENT_STRIP = _CREATE + _COMMON + ("to my calendar", "in my calendar", "on my calendar", "calendar mein",
                                    "कैलेंडर में", "an event", "event", "इवेंट", "a")  # fmt: skip


def extract_event(text: str, ctx: IntentContext) -> Slots | None:
    if not (_has(text, _EVENT) and _has(text, _CREATE)) or _has(text, _NEXT_MEETING):
        return None
    slots, spans = _base(text)
    when = _when(text, ctx, slots, spans)
    if when is None or not when.has_time:
        slots["_missing"] = ["start_at"]
    else:
        slots["start_at"] = when.at.isoformat()
        length = parse_duration(remove_spans(text, spans))
        if length is not None and length.seconds <= 24 * 3600:
            slots["end_at"] = (when.at + timedelta(seconds=length.seconds)).isoformat()
            spans += list(length.spans)
    title = clean_title(text, _EVENT_STRIP, spans)
    slots["title"] = title or ("Meeting" if _has(text, ("meeting", "मीटिंग")) else "Event")
    return slots


# ---------------------------------------------------------------- contacts

_CONTACT = ("save contact", "add contact", "new contact", "save number", "save the number", "number save",
            "contact save", "नंबर सेव", "कॉन्टैक्ट सेव", "नया कॉन्टैक्ट", "number", "नंबर", "contact", "कॉन्टैक्ट")  # fmt: skip
_SAVE = ("save", "add", "store", "sev", "सेव", "जोड़", "जोड़ो", "रख लो", "rakh lo")


def extract_contact(text: str, ctx: IntentContext) -> Slots | None:
    if not (_has(text, _CONTACT) and _has(text, _SAVE)):
        return None
    slots, spans = _base(text)
    country = "91" if ctx.timezone in ("Asia/Kolkata", "Asia/Calcutta") else ""
    phone, phone_span = extract_phone(text, default_country=country or "91")
    email, email_span = extract_email(text)
    if phone:
        slots["phone"] = phone
    if email:
        slots["email"] = email
    spans += [s for s in (phone_span, email_span) if s]
    cleaned = re.sub(r"['’]s\b", lambda m: " " * len(m.group(0)), text)
    name = clean_title(cleaned, _CONTACT + _SAVE + _COMMON + ("as", "of", "phone", "email", "with"), spans)
    parts = name.split()
    if not parts:
        slots["_missing"] = ["given_name"]
        return slots
    slots["given_name"] = parts[0]
    if len(parts) > 1:
        slots["family_name"] = " ".join(parts[1:])
    return slots


# ---------------------------------------------------------------- shortcuts and opening things

_SHORTCUT = ("shortcut", "shortcuts", "शॉर्टकट")
_RUN = ("run", "start", "trigger", "chalao", "chala do", "चलाओ", "चला दो", "my", "the", "named", "called", "mera",
        "मेरा")  # fmt: skip


def extract_shortcut(text: str, ctx: IntentContext) -> Slots | None:
    if not _has(text, _SHORTCUT):
        return None
    slots, spans = _base(text)
    name = clean_title(text, _SHORTCUT + _RUN + _COMMON, spans)
    if name:
        slots["name"] = name
    else:
        slots["_missing"] = ["name"]
    return slots


_OPEN = ("open", "launch", "kholo", "khol do", "kholna", "खोलो", "खोल दो", "खोलना")
_KNOWN_APPS = {
    "spotify": "spotify:", "स्पॉटिफ़ाई": "spotify:", "apple music": "music://", "music": "music://",
    "maps": "maps://", "apple maps": "maps://", "shortcuts": "shortcuts://", "calendar": "calshow:",
    "photos": "photos-redirect://", "youtube": "https://www.youtube.com", "यूट्यूब": "https://www.youtube.com",
    "google": "https://www.google.com", "गूगल": "https://www.google.com", "gmail": "https://mail.google.com",
    "whatsapp": "https://wa.me/", "व्हाट्सऐप": "https://wa.me/", "व्हाट्सएप": "https://wa.me/",
}  # fmt: skip
_URL = re.compile(r"https://[^\s]+", re.IGNORECASE)
_DOMAIN = re.compile(r"(?<![\w@/.])((?:[a-z0-9-]+\.)+[a-z]{2,})(/[^\s]*)?", re.IGNORECASE)


def extract_open(text: str, ctx: IntentContext) -> Slots | None:
    if not _has(text, _OPEN) or _has(text, ("file", "files", "फ़ाइल", "फाइल", "document")):
        return None
    slots, _ = _base(text)
    if m := _URL.search(text):
        slots["url"] = m.group(0).rstrip(".,!?")
        return slots
    if m := _DOMAIN.search(text):
        slots["url"] = "https://" + m.group(0).rstrip(".,!?")
        return slots
    t = norm(text)
    for name in sorted(_KNOWN_APPS, key=len, reverse=True):
        if re.search(rf"{L}{re.escape(norm(name))}{R}", t):
            slots["url"] = _KNOWN_APPS[name]
            return slots
    slots["_missing"] = ["url"]
    return slots


# ---------------------------------------------------------------- lights (Home Assistant)

_LIGHT = ("light", "lights", "lamp", "lamps", "bulb", "batti", "battiyan", "बत्ती", "बत्तियाँ", "लाइट", "लाइटें")
_QUESTION = re.compile(rf"^\s*(?:is|are|kya|क्या){R}")
_PERCENT = re.compile(r"(\d{1,3})\s*(?:%|percent|pratishat|प्रतिशत)")


def make_lights_extractor(
    config: Callable[[], HomeAssistantConfig],
) -> Callable[[str, IntentContext], Slots | None]:
    def extract(text: str, ctx: IntentContext) -> Slots | None:
        service = extract_switch(text)
        if not _has(text, _LIGHT) or service is None or _QUESTION.search(norm(text)):
            return None
        slots, _ = _base(text)
        t = norm(text)
        lights = [e for e in config().entities if e.domain == "light"]
        named = [
            e for e in lights
            if any(re.search(rf"{L}{re.escape(norm(n))}{R}", t) for n in (e.name, *e.aliases))
        ]  # fmt: skip
        slots.update(
            {"domain": "light", "service": service, "entity_ids": [e.entity_id for e in named or lights]}
        )
        if service == "turn_on" and (m := _PERCENT.search(t)) and int(m.group(1)) <= 100:
            slots["brightness_pct"] = int(m.group(1))
        return slots

    return extract


# ---------------------------------------------------------------- specs


def device_intents(ha_config: Callable[[], HomeAssistantConfig]) -> list[IntentSpec]:
    dc = AgentId.DEVICE_CONTROL
    return [
        IntentSpec("devices.set_alarm", dc, "ios.alarm.create",
                   {"en": ["alarm", "wake me up"], "hi": ["अलार्म", "जगा देना"], "hinglish": ["alarm", "jaga dena"]},
                   extract_alarm, ("set an alarm for 7 AM", "कल सुबह 7 बजे का अलार्म लगा दो"), priority=10),
        IntentSpec("devices.start_timer", dc, "ios.timer.start",
                   {"en": ["timer", "countdown"], "hi": ["टाइमर"], "hinglish": ["timer", "timer lagao"]},
                   extract_timer, ("start a 10 minute timer", "das minute ka timer lagao"), priority=10),
        IntentSpec("devices.create_reminder", dc, "device.reminder.create",
                   {"en": ["remind me", "reminder"], "hi": ["याद दिलाना", "रिमाइंडर"],
                    "hinglish": ["yaad dilana", "reminder"]},
                   extract_reminder, ("remind me to call mom tomorrow at 7 pm",), priority=10),
        IntentSpec("devices.create_event", dc, "device.calendar.create_event",
                   {"en": ["add to calendar", "schedule a meeting"], "hi": ["कैलेंडर में जोड़ो", "मीटिंग रख दो"],
                    "hinglish": ["calendar mein add karo", "meeting rakh do"]},
                   extract_event, ("schedule a meeting with Rahul tomorrow at 3 pm",), priority=5),
        IntentSpec("devices.next_meeting", dc, "device.calendar.upcoming",
                   {"en": ["next meeting", "my schedule"], "hi": ["अगली मीटिंग", "आज की मीटिंग"],
                    "hinglish": ["agli meeting", "aaj ki meetings"]},
                   extract_next_meeting, ("when is my next meeting",), priority=20),
        IntentSpec("devices.save_contact", dc, "device.contacts.save",
                   {"en": ["save contact", "save number"], "hi": ["नंबर सेव करो"], "hinglish": ["number save karo"]},
                   extract_contact, ("save Rahul's number 98765 43210",), priority=10),
        IntentSpec("devices.run_shortcut", dc, "device.shortcut.run",
                   {"en": ["run shortcut"], "hi": ["शॉर्टकट चलाओ"], "hinglish": ["shortcut chalao"]},
                   extract_shortcut, ("run my Good Morning shortcut",), priority=10),
        IntentSpec("devices.open", dc, "device.open_url",
                   {"en": ["open", "launch"], "hi": ["खोलो"], "hinglish": ["kholo", "khol do"]},
                   extract_open, ("open YouTube on my Mac",), priority=0),
        IntentSpec("devices.lights", dc, "homeassistant.call_service",
                   {"en": ["lights on", "lights off"], "hi": ["बत्ती जलाओ", "बत्ती बंद करो"],
                    "hinglish": ["light on karo", "batti band karo"]},
                   make_lights_extractor(ha_config), ("turn off the bedroom lights",), priority=10),
    ]  # fmt: skip
