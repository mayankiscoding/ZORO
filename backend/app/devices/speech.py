"""Spoken summaries, cards and approval views for the device tools.

Summaries are one short sentence in "en", "hi" (Devanagari) or "hinglish" (romanised), built only
from values in the result (titles, names, times as the device reported them), never invented.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from typing import Any

from app.devices import tool_io as io
from app.schemas.common import LabelValue, UICard
from app.tools.spec import ApprovalView

Lines = tuple[str, str, str]  # en, hi, hinglish


def pick(lang: str, lines: Lines) -> str:
    en, hi, hinglish = lines
    return {"hi": hi, "hinglish": hinglish}.get(lang, en)


def _hhmm(moment: datetime) -> str:
    """Wall-clock time in the offset the device reported (so the digits are those of the result)."""
    return moment.strftime("%H:%M")


def _number(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else str(value)


def _fixed(lines: Lines) -> Callable[[Any, str], str]:
    return lambda _result, lang: pick(lang, lines)


def _opened(result: io.OpenedOut, lang: str) -> str:
    if result.opened:
        return pick(lang, ("Opened.", "खोल दिया।", "Khol diya."))
    return pick(lang, ("It could not be opened.", "यह खुल नहीं पाया।", "Ye khul nahi paaya."))


def _upcoming(result: io.UpcomingOut, lang: str) -> str:
    if not result.events:
        return pick(lang, ("No upcoming events.", "कोई आने वाला इवेंट नहीं है।", "Koi upcoming event nahi hai."))
    event = result.events[0]
    t, at = event.title, _hhmm(event.start_at)
    return pick(lang, (f"Next up: {t} at {at}.", f"अगला: {t}, {at} बजे।", f"Agla: {t}, {at} baje."))


def _contacts(result: io.ContactsFindOut, lang: str) -> str:
    if not result.matches:
        return pick(lang, ("No matching contact.", "ऐसा कोई कॉन्टैक्ट नहीं मिला।", "Aisa koi contact nahi mila."))
    name = result.matches[0].name
    if len(result.matches) == 1:
        return pick(lang, (f"Found {name}.", f"{name} मिल गए।", f"{name} mil gaye."))
    return pick(lang, (f"Found {name} and others.", f"{name} और कुछ और मिले।", f"{name} aur kuch aur mile."))


def _location(result: io.LocationOut, lang: str) -> str:
    if result.locality:
        loc = result.locality
        return pick(lang, (f"You are near {loc}.", f"आप {loc} के पास हैं।", f"Aap {loc} ke paas ho."))
    return pick(lang, ("Got your current location.", "आपकी लोकेशन मिल गई।", "Aapki location mil gayi."))


def _started(result: io.StartedOut, lang: str) -> str:
    if result.started:
        return pick(lang, ("Shortcut started.", "शॉर्टकट शुरू हो गया।", "Shortcut shuru ho gaya."))
    return pick(lang, ("The shortcut did not start.", "शॉर्टकट शुरू नहीं हुआ।", "Shortcut shuru nahi hua."))


def _music(result: io.MusicControlOut, lang: str) -> str:
    now = result.now_playing
    if now is None:
        return pick(lang, ("Done.", "हो गया।", "Ho gaya."))
    t, a = now.title, now.artist
    return pick(lang, (f"Playing {t} by {a}.", f"{a} का {t} चल रहा है।", f"{a} ka {t} chal raha hai."))


def _photos(result: io.PhotosSearchOut, lang: str) -> str:
    if result.hits:
        lines: Lines = ("Found matching photos.", "मिलती-जुलती फ़ोटो मिल गईं।", "Matching photos mil gayi.")
    else:
        lines = ("No matching photos.", "कोई मिलती फ़ोटो नहीं मिली।", "Koi matching photo nahi mili.")
    text = pick(lang, lines)
    if result.limited_library:
        text += " " + pick(
            lang,
            (
                "Only part of your library is shared with ZORO.",
                "ZORO को लाइब्रेरी का कुछ हिस्सा ही मिला है।",
                "ZORO ko library ka sirf kuch hissa mila hai.",
            ),
        )
    return text


def _health(result: io.HealthQueryOut, lang: str) -> str:
    if not result.points:
        return pick(
            lang,
            (
                "No Health data for that range.",
                "उस समय का हेल्थ डेटा नहीं है।",
                "Us time ka health data nahi hai.",
            ),
        )
    last = result.points[-1]
    v, u = _number(last.value), last.unit
    return pick(lang, (f"Latest: {v} {u}.", f"सबसे हाल का: {v} {u}।", f"Latest: {v} {u}."))


def _message(result: io.MessageComposeOut, lang: str) -> str:
    if result.sent is True:
        return pick(lang, ("Message sent.", "मैसेज भेज दिया गया।", "Message bhej diya gaya."))
    if result.sent is False or not result.presented:
        return pick(lang, ("The message was not sent.", "मैसेज नहीं भेजा गया।", "Message nahi bheja gaya."))
    return pick(
        lang, ("The message is ready; tap send.", "मैसेज तैयार है, सेंड दबाएँ।", "Message ready hai, send dabao.")
    )


def _ran(result: io.RanOut, lang: str) -> str:
    if result.ran:
        return pick(lang, ("Scene is running.", "सीन चल गया।", "Scene chal gaya."))
    return pick(lang, ("The scene did not run.", "सीन नहीं चला।", "Scene nahi chala."))


def _files(result: io.FileSearchOut, lang: str) -> str:
    if not result.files:
        return pick(lang, ("No files found.", "कोई फ़ाइल नहीं मिली।", "Koi file nahi mili."))
    n = result.files[0].name
    return pick(lang, (f"Found {n}.", f"{n} मिल गई।", f"{n} mil gayi."))


SUMMARIZERS: dict[str, Callable[[Any, str], str]] = {
    "device.reminder.create": _fixed(("Reminder saved.", "रिमाइंडर सेव हो गया।", "Reminder save ho gaya.")),
    "device.calendar.create_event": _fixed(
        ("Event added to your calendar.", "कैलेंडर में इवेंट जुड़ गया।", "Calendar mein event add ho gaya.")
    ),
    "device.calendar.upcoming": _upcoming,
    "device.contacts.find": _contacts,
    "device.contacts.save": _fixed(("Contact saved.", "कॉन्टैक्ट सेव हो गया।", "Contact save ho gaya.")),
    "device.notification.schedule": _fixed(
        ("Notification scheduled.", "नोटिफ़िकेशन सेट हो गया।", "Notification set ho gaya.")
    ),
    "device.location.current": _location,
    "device.open_url": _opened,
    "device.shortcut.run": _started,
    "device.music.control": _music,
    "device.photos.search": _photos,
    "device.health.query": _health,
    "device.whatsapp.compose": _fixed(
        (
            "WhatsApp is open with your message; tap send.",
            "व्हाट्सऐप में मैसेज तैयार है, सेंड दबाएँ।",
            "WhatsApp mein message ready hai, send dabao.",
        )
    ),
    "ios.alarm.create": _fixed(("Alarm set.", "अलार्म लग गया।", "Alarm lag gaya.")),
    "ios.timer.start": _fixed(("Timer started.", "टाइमर शुरू हो गया।", "Timer shuru ho gaya.")),
    "ios.message.compose": _message,
    "ios.home.run_scene": _ran,
    "mac.applescript.run": _fixed(("The script ran.", "स्क्रिप्ट चल गई।", "Script chal gayi.")),
    "mac.file.search": _files,
    "mac.file.open": _opened,
}


# ---------------------------------------------------------------- cards


def _card(kind: str, title: str, key: str) -> Callable[[Any], UICard | None]:
    def build(result: Any) -> UICard | None:
        payload = result.model_dump(mode="json")
        if not payload.get(key):
            return None
        return UICard(kind=kind, title=title, payload=payload)

    return build


CARDS: dict[str, Callable[[Any], UICard | None]] = {
    "device.calendar.upcoming": _card("calendar_events", "Upcoming", "events"),
    "device.contacts.find": _card("contacts", "Contacts", "matches"),
    "device.music.control": _card("music", "Now playing", "now_playing"),
    "device.photos.search": _card("photo_query", "Photos", "hits"),
    "device.health.query": _card("health_series", "Health", "points"),
    "mac.file.search": _card("files", "Files", "files"),
}


# ---------------------------------------------------------------- approval views


def _whatsapp_view(args: io.WhatsAppComposeIn) -> ApprovalView:
    number = f"+{args.phone}" if args.phone else "a chat you pick in WhatsApp"
    to = f"{args.recipient_name}, {number}" if args.recipient_name else number
    details = [LabelValue(label="To", value=to)]
    if args.recipient_name:
        details = [
            LabelValue(label="Name", value=args.recipient_name),
            LabelValue(label="Number", value=number),
        ]
    return ApprovalView(
        title=f"Prepare a WhatsApp message to {to}",
        summary=args.text,
        details=(
            *details,
            LabelValue(label="Message", value=args.text),
            LabelValue(label="Note", value="Opens WhatsApp with this text. You tap send there."),
        ),
    )


def _message_view(args: io.MessageComposeIn) -> ApprovalView:
    numbers = ", ".join(f"+{r}" for r in args.recipients)
    to = f"{args.recipient_name}, {numbers}" if args.recipient_name else numbers
    return ApprovalView(
        title=f"Prepare a message to {to}",
        summary=args.body,
        details=(
            LabelValue(label="To", value=to),
            LabelValue(label="Message", value=args.body),
            LabelValue(label="Note", value="Opens Messages with this text. You tap send there."),
        ),
    )


def _shortcut_view(args: io.ShortcutRunIn) -> ApprovalView:
    details = [LabelValue(label="Shortcut", value=args.name)]
    if args.input:
        details.append(LabelValue(label="Input", value=args.input))
    return ApprovalView(
        title=f"Run the shortcut “{args.name}”", summary=args.input or args.name, details=tuple(details)
    )


def _script_view(args: io.AppleScriptRunIn) -> ApprovalView:
    params = ", ".join(f"{k}={v}" for k, v in (args.params or {}).items())
    return ApprovalView(
        title=f"Run the AppleScript “{args.script_id}” on your Mac",
        summary=params or args.script_id,
        details=(
            LabelValue(label="Script", value=args.script_id),
            LabelValue(label="Parameters", value=params),
        ),
    )


APPROVAL_VIEWS: dict[str, Callable[[Any], ApprovalView]] = {
    "device.whatsapp.compose": _whatsapp_view,
    "ios.message.compose": _message_view,
    "device.shortcut.run": _shortcut_view,
    "mac.applescript.run": _script_view,
}
