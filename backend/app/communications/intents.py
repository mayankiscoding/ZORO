"""Communications intents with deterministic slot filling (English, Hindi, Hinglish).

Extractors return tool arguments. Keys starting with "_" are hints for the orchestrator (`_missing`:
slots not found, `_assumptions`) and are ignored by the tools' input models.
Sending is never an intent by itself: "message Priya saying ..." routes to `communications.draft_message`,
the draft is shown, and only the owner's approval of `send_message` / `send_email` sends anything.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from typing import Any

from app.core.types import AgentId
from app.tools.intents import IntentContext, IntentSpec

Slots = dict[str, Any]
_EDGE = r"[\s.,!?;:'\"()]"


def norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.replace("’", "'")).strip()


def has(text: str, words: Iterable[str]) -> bool:
    t = f" {norm(text).lower()} "
    return any(re.search(rf"(?<={_EDGE}){re.escape(w)}(?={_EDGE})", t) for w in words)


def strip_words(text: str, words: Iterable[str]) -> str:
    t = f" {norm(text)} "
    for w in sorted(set(words), key=len, reverse=True):
        t = re.sub(rf"(?<={_EDGE}){re.escape(w)}(?={_EDGE})", " ", t, flags=re.IGNORECASE)
    return re.sub(r"\s+", " ", t).strip(" .,:;-")


WHATSAPP = ("whatsapp", "whats app", "व्हाट्सऐप", "व्हाट्सएप", "वॉट्सऐप", "व्हाट्सअप", "वाट्सऐप")
EMAIL = ("email", "emails", "e-mail", "mail", "mails", "ईमेल", "मेल", "इमेल")
SMS = ("sms", "text message", "एसएमएस")
IMESSAGE = ("imessage", "आईमैसेज")
MESSAGE = ("message", "msg", "मैसेज", "संदेश", "text")
SEND = ("send", "text", "message", "msg", "whatsapp", "mail", "email", "tell", "drop", "bhejo", "bhej do", "bhejna",
        "bolo", "bol do", "karo", "kar do", "भेजो", "भेज दो", "बोलो", "बोल दो", "करो", "कर दो")  # fmt: skip
DRAFT_ONLY = ("draft", "write", "prepare", "compose", "likho", "likh do", "ड्राफ्ट", "लिखो", "लिख दो")
SEARCH = ("find", "search", "look for", "look up", "show", "check", "any", "dhundo", "dhoondo", "khojo", "dikhao",
          "सर्च", "खोजो", "ढूंढो", "ढूँढो", "दिखाओ", "देखो")  # fmt: skip
READ = ("read", "open", "padho", "padh do", "kholo", "पढ़ो", "पढ़ दो", "खोलो", "सुनाओ", "sunao")
SUMMARY = ("summarize", "summarise", "summary", "saransh", "summary batao", "सारांश", "समरी", "संक्षेप")
THREAD = ("email", "emails", "mail", "thread", "ईमेल", "मेल", "थ्रेड", "इमेल")
_SEPARATORS = (
    r"\s+saying\s+",
    r"\s+that\s+",
    r"\s+ki\s+",
    r"\s+कि\s+",
    r"\s*:\s*",
    r"\s+says\s+",
    r"\s+about\s+",
)
_ORDINALS: dict[str, int] = {
    "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "fifth": 5,
    "pehla": 1, "pehle": 1, "pehli": 1, "पहला": 1, "पहले": 1, "पहली": 1,
    "doosra": 2, "dusra": 2, "doosre": 2, "dusre": 2, "doosri": 2, "दूसरा": 2, "दूसरे": 2, "दूसरी": 2,
    "teesra": 3, "tisra": 3, "teesre": 3, "तीसरा": 3, "तीसरे": 3, "तीसरी": 3,
    "chautha": 4, "chauthe": 4, "चौथा": 4, "चौथे": 4,
}  # fmt: skip


def channel_of(text: str) -> tuple[str | None, bool]:
    """(channel, assumed). A bare "message" is assumed to be WhatsApp and flagged."""
    if has(text, WHATSAPP):
        return "whatsapp", False
    if has(text, IMESSAGE):
        return "imessage", False
    if has(text, EMAIL):
        return "email", False
    if has(text, SMS):
        return "sms", False
    if has(text, MESSAGE):
        return "whatsapp", True
    return None, False


def _ordinal(text: str) -> int | None:
    t = norm(text).lower()
    for word, n in _ORDINALS.items():
        if has(t, (word,)):
            return n
    m = re.search(rf"(?<={_EDGE})(?:number|no\.?|#|नंबर)\s*(\d)(?={_EDGE})", f" {t} ")
    return int(m.group(1)) if m else None


# ---------------------------------------------------------------- draft_message

_LEAD = (
    "send", "a", "an", "the", "new", "please", "can you", "could you", "to", "message", "msg", "text", "whatsapp",
    "email", "mail", "sms", "imessage", "tell", "drop", "ko", "को", "karo", "kar do", "bhejo", "bhej do", "bolo",
    "bol do", "bhejna", "करो", "कर दो", "भेजो", "भेज दो", "बोलो", "बोल दो", "मैसेज", "संदेश", "ईमेल", "मेल",
    "व्हाट्सऐप", "व्हाट्सएप", "वॉट्सऐप", "व्हाट्सअप", "एसएमएस", "आईमैसेज", "on", "par", "पर", "pe", "via", "my",
    "ek", "एक", "ye", "ये", "naya", "नया", "message", "text message", "whats app", "e-mail",
)  # fmt: skip


def extract_draft(text: str, ctx: IntentContext) -> Slots | None:
    t = norm(text)
    channel, assumed = channel_of(t)
    if has(t, SEARCH) and channel == "email":
        return None  # that is a mailbox search
    if has(t, SUMMARY) or (has(t, READ) and has(t, THREAD)):
        return None
    tell = has(t, ("tell", "bolo", "bol do", "बोलो", "बोल दो"))
    if channel is None and not tell:
        return None
    parts = None
    for sep in _SEPARATORS:
        m = re.search(sep, t, flags=re.IGNORECASE)
        if m:
            parts = (t[: m.start()], t[m.end() :])
            break
    if parts is None:
        if channel is None or not has(t, SEND):
            return None
        head, body = t, ""
    else:
        head, body = parts
    # "send / tell / message ..." asks for the send (which still waits for approval); "draft /
    # write / prepare ..." only asks for the draft.
    slots: Slots = {"channel": channel or "whatsapp", "send": not has(head, DRAFT_ONLY)}
    if channel is None or assumed:
        slots["_assumptions"] = ["channel_default_whatsapp"]
    name = strip_words(head, _LEAD)
    # "send ... to Priya" keeps only the name; Hindi/Hinglish "Priya ko" was stripped with "ko"
    name = re.sub(r"^(?:to|ko|को)\s+", "", name, flags=re.IGNORECASE).strip()
    address = re.search(r"[\w.+-]+@[\w-]+\.[\w.-]+|\+?\d[\d\s-]{8,}\d", name)
    missing: list[str] = []
    if address:
        slots["recipient"] = address.group(0).strip()
    elif name:
        slots["recipient_query"] = name
    else:
        missing.append("recipient")
    if body.strip():
        slots["text"] = body.strip()
    else:
        missing.append("text")
    if missing:
        slots["_missing"] = missing
    return slots


# ---------------------------------------------------------------- find_email

_QUERY_STOP = (
    *SEARCH, *EMAIL, "all", "my", "the", "a", "an", "for", "me", "mere", "mera", "meri", "ka", "ke", "ki", "ko",
    "mein", "में", "का", "के", "की", "को", "मेरे", "मेरा", "मेरी", "email", "emails", "inbox", "please", "karo",
    "kar do", "करो", "कर दो", "kya", "क्या", "hai", "है", "mile", "मिले", "aaya", "आया", "latest", "recent",
)  # fmt: skip
_ABOUT = r"(?:about|regarding|re|subject|ke baare mein|ke bare mein|के बारे में|बारे में)"
_FROM = r"(?:se|से)"


def extract_find_email(text: str, ctx: IntentContext) -> Slots | None:
    t = norm(text)
    if not has(t, EMAIL) or not has(t, SEARCH):
        return None
    if has(t, SUMMARY) or has(t, ("send", "bhejo", "भेजो", "draft")):
        return None
    terms: list[str] = []
    rest = t
    if has(t, ("unread", "unseen", "अनपढ़े", "unread wale")):
        terms.append("is:unread")
        rest = strip_words(rest, ("unread", "unseen", "अनपढ़े", "unread wale"))
    sender = re.search(rf"(?:^|\s)from\s+(.+?)(?=\s+{_ABOUT}\s|\s*$)", rest, flags=re.IGNORECASE)
    if sender:
        who = strip_words(sender.group(1), _QUERY_STOP)
        if who:
            terms.append(f"from:{who.replace(' ', '.') if '@' in who else who}")
        rest = rest.replace(sender.group(0), " ")
    else:  # Hinglish / Hindi: "Amazon ka email", "अमेज़न से आया ईमेल"
        m = re.search(
            rf"(.+?)\s+(?:ka|ke|की|का|के|{_FROM})\s+(?:aaya|आया|email|mail|ईमेल|मेल)", rest, flags=re.IGNORECASE
        )
        if m:
            who = strip_words(m.group(1), _QUERY_STOP)
            if who:
                terms.append(f"from:{who}")
            rest = rest.replace(m.group(0), " ")
    about = re.search(rf"{_ABOUT}\s+(.+)$", rest, flags=re.IGNORECASE)
    if about:
        topic = strip_words(about.group(1), _QUERY_STOP)
        if topic:
            terms.append(topic)
        rest = rest[: about.start()]
    leftover = strip_words(rest, _QUERY_STOP)
    if (leftover and not terms) or (leftover and leftover not in " ".join(terms)):
        terms.append(leftover)
    query = " ".join(terms).strip()
    return {"query": query} if query else {"_missing": ["query"]}


# ---------------------------------------------------------------- read / summarize


def _ref(text: str, ctx: IntentContext) -> Slots | None:
    shown = ctx.working_sets.get("emails") or []
    if not shown:
        return None  # nothing has been shown, so there is nothing to point at
    ordinal = _ordinal(text)
    if ordinal is not None:
        return {"ref": ordinal} if ordinal <= len(shown) else {"_missing": ["ref"]}
    if len(shown) == 1 or has(text, ("this", "that", "ye", "yeh", "is", "इस", "यह", "ये")):
        return {"ref": 1}
    return {"_missing": ["ref"]}


def extract_read(text: str, ctx: IntentContext) -> Slots | None:
    if not (has(text, READ) and has(text, THREAD)) or has(text, SUMMARY) or has(text, SEARCH):
        return None
    return _ref(text, ctx)


def extract_summarize(text: str, ctx: IntentContext) -> Slots | None:
    if not (has(text, SUMMARY) and has(text, THREAD)):
        return None
    return _ref(text, ctx)


# ---------------------------------------------------------------- specs

_C = AgentId.COMMUNICATION


def communication_intents() -> list[IntentSpec]:
    return [
        IntentSpec(
            "communications.draft_message", _C, "communications.draft_message",
            {"en": ["send a message to", "whatsapp", "text", "email", "tell", "message"],
             "hi": ["व्हाट्सऐप", "मैसेज भेजो", "ईमेल भेजो", "बोलो कि", "को संदेश"],
             "hinglish": ["whatsapp karo", "message bhejo", "email bhejo", "ko bolo ki", "ko message karo"]},
            extract_draft, priority=1,
            examples=("WhatsApp Priya saying I will be late", "email hr@example.com saying I am on leave tomorrow",
                      "प्रिया को व्हाट्सऐप करो कि मैं देर से आऊँगा", "Rahul ko message bhejo ki kal milte hain"),
        ),
        IntentSpec(
            "communications.find_email", _C, "communications.find_email",
            {"en": ["find emails from", "search my email", "any email about", "show unread emails"],
             "hi": ["ईमेल खोजो", "मेरे ईमेल में ढूंढो", "ईमेल दिखाओ"],
             "hinglish": ["email dhundo", "mere email mein dhundo", "email dikhao", "se aaya email"]},
            extract_find_email, priority=2,
            examples=("find emails from Amazon about my refund", "अमेज़न से आया ईमेल खोजो", "Amazon ka email dhundo"),
        ),
        IntentSpec(
            "communications.read_thread", _C, "communications.read_thread",
            {"en": ["read the second email", "open the first email", "read that thread"],
             "hi": ["दूसरा ईमेल पढ़ो", "पहला ईमेल खोलो"],
             "hinglish": ["doosra email padho", "pehla email kholo"]},
            extract_read, priority=2,
            examples=("read the second email", "पहला ईमेल पढ़ो", "doosra email padho"),
        ),
        IntentSpec(
            "communications.summarize_thread", _C, "communications.summarize_thread",
            {"en": ["summarize the email", "summary of the second email", "summarise this thread"],
             "hi": ["ईमेल का सारांश", "दूसरे ईमेल का सारांश बताओ"],
             "hinglish": ["email ka summary batao", "doosre email ka summary"]},
            extract_summarize, priority=3,
            examples=("summarize the second email", "दूसरे ईमेल का सारांश बताओ", "pehle email ka summary batao"),
        ),
    ]  # fmt: skip
