"""Spoken summaries (en, hi, hinglish), cards and approval views for the communications tools.

Every sentence is built only from values in the result (names, addresses, subjects, counts)."""

from __future__ import annotations

from app.communications.recipients import display_phone
from app.communications.schemas import (
    DraftMessageOut,
    EmailDraftIn,
    EmailDraftOut,
    FindEmailOut,
    ReadThreadOut,
    SendEmailIn,
    SendEmailOut,
    SendMessageIn,
    SendMessageOut,
    SummarizeThreadOut,
)
from app.schemas.common import LabelValue, UICard
from app.tools.spec import ApprovalView

Lines = tuple[str, str, str]
CHANNEL: dict[str, Lines] = {
    "whatsapp": ("WhatsApp", "व्हाट्सऐप", "WhatsApp"),
    "sms": ("SMS", "एसएमएस", "SMS"),
    "imessage": ("iMessage", "आईमैसेज", "iMessage"),
    "email": ("email", "ईमेल", "email"),
}


def pick(lang: str, lines: Lines) -> str:
    en, hi, hinglish = lines
    return {"hi": hi, "hinglish": hinglish}.get(lang, en)


def channel_name(channel: str, lang: str) -> str:
    return pick(lang, CHANNEL.get(channel, (channel, channel, channel)))


def gmail_line(status: str, lang: str) -> str | None:
    table: dict[str, Lines] = {
        "not_configured": (
            "Gmail is not set up on the server yet.",
            "सर्वर पर Gmail अभी सेट नहीं है।",
            "Server par Gmail abhi set up nahi hai.",
        ),
        "not_connected": (
            "Gmail is not connected. Connect it in Integrations.",
            "Gmail जुड़ा नहीं है। इंटीग्रेशन में जाकर जोड़ें।",
            "Gmail connect nahi hai. Integrations mein jaakar connect karo.",
        ),
        "expired": (
            "Your Google sign-in expired. Connect Gmail again.",
            "आपका Google साइन-इन ख़त्म हो गया है। Gmail दोबारा जोड़ें।",
            "Aapka Google sign-in expire ho gaya hai. Gmail dobara connect karo.",
        ),
        "forbidden": (
            "Google did not allow this. Reconnect Gmail and accept every permission.",
            "Google ने इसकी अनुमति नहीं दी। Gmail दोबारा जोड़ें और सभी अनुमतियाँ दें।",
            "Google ne iski permission nahi di. Gmail dobara connect karo aur saari permissions do.",
        ),
        "rate_limited": (
            "Gmail is busy. Try again shortly.",
            "Gmail अभी व्यस्त है। थोड़ी देर में फिर कोशिश करें।",
            "Gmail abhi busy hai. Thodi der mein phir try karo.",
        ),
        "not_found": (
            "I could not find that email.",
            "वह ईमेल नहीं मिला।",
            "Wo email nahi mila.",
        ),
        "unavailable": (
            "Gmail is not answering right now.",
            "Gmail अभी जवाब नहीं दे रहा।",
            "Gmail abhi jawab nahi de raha.",
        ),
    }
    return pick(lang, table[status]) if status in table else None


# ---------------------------------------------------------------- draft_message


def draft_summary(r: DraftMessageOut, lang: str) -> str:
    q = r.query or ""
    if r.status == "prepared" and r.draft is not None:
        d = r.draft
        label = d.recipient_address if d.channel == "email" else display_phone(d.recipient_address)
        ch = channel_name(d.channel, lang)
        return pick(
            lang,
            (
                f"Draft {ch} for {d.recipient_display}, {label}, is ready. Say send to confirm.",
                f"{d.recipient_display}, {label} के लिए {ch} ड्राफ्ट तैयार है। भेजने के लिए कहें।",
                f"{d.recipient_display}, {label} ke liye {ch} draft ready hai. Bhejne ke liye bolo.",
            ),
        )
    if r.status == "ambiguous":
        names = "; ".join(f"{c.name}, {c.label}" for c in r.candidates)
        return pick(
            lang,
            (
                f"I found {len(r.candidates)} matches: {names}. Which one?",
                f"{len(r.candidates)} मिलते-जुलते नाम मिले: {names}। कौन सा?",
                f"{len(r.candidates)} matches mile: {names}. Kaun sa?",
            ),
        )
    if r.status == "needs_contact_lookup":
        return pick(
            lang,
            (
                f"I will look up {q} in your contacts.",
                f"मैं आपके कॉन्टैक्ट में {q} खोजता हूँ।",
                f"Main aapke contacts mein {q} dhundta hoon.",
            ),
        )
    if r.status == "no_contact":
        if r.message == "no_phone":
            return pick(
                lang,
                (
                    f"{q} has no phone number saved.",
                    f"{q} का कोई फ़ोन नंबर सेव नहीं है।",
                    f"{q} ka koi phone number save nahi hai.",
                ),
            )
        if r.message == "no_email":
            return pick(
                lang,
                (
                    f"{q} has no email address saved.",
                    f"{q} का कोई ईमेल पता सेव नहीं है।",
                    f"{q} ka koi email address save nahi hai.",
                ),
            )
        return pick(
            lang,
            (
                f"I could not find {q} in your contacts.",
                f"आपके कॉन्टैक्ट में {q} नहीं मिला।",
                f"Aapke contacts mein {q} nahi mila.",
            ),
        )
    if r.status == "invalid":
        return pick(
            lang,
            (
                "That is not a valid number or address.",
                "यह सही नंबर या पता नहीं है।",
                "Ye sahi number ya address nahi hai.",
            ),
        )
    return pick(lang, ("Who should I send it to?", "किसे भेजना है?", "Kisko bhejna hai?"))


def draft_card(r: DraftMessageOut) -> UICard | None:
    if r.draft is None:
        return None
    return UICard(kind="message_draft", title="Draft", payload=r.draft.model_dump(mode="json"))


# ---------------------------------------------------------------- email reading


def find_summary(r: FindEmailOut, lang: str) -> str:
    line = gmail_line(r.status, lang) if r.status != "ok" else None
    if line:
        return line
    if not r.emails:
        return pick(lang, ("No emails matched.", "कोई ईमेल नहीं मिला।", "Koi email nahi mila."))
    first, n = r.emails[0], len(r.emails)
    return pick(
        lang,
        (
            f"Found {n} emails. The first is from {first.sender}: {first.subject}.",
            f"{n} ईमेल मिले। पहला {first.sender} का है: {first.subject}।",
            f"{n} email mile. Pehla {first.sender} ka hai: {first.subject}.",
        ),
    )


def find_card(r: FindEmailOut) -> UICard | None:
    if not r.emails:
        return None
    return UICard(kind="emails", title="Emails", payload=r.model_dump(mode="json"))


def read_summary(r: ReadThreadOut, lang: str) -> str:
    line = gmail_line(r.status, lang) if r.status != "ok" else None
    if line:
        return line
    n = len(r.messages)
    latest = r.messages[-1].sender if r.messages else ""
    return pick(
        lang,
        (
            f"The thread {r.subject} has {n} messages. The latest is from {latest}.",
            f"थ्रेड {r.subject} में {n} संदेश हैं। सबसे नया {latest} का है।",
            f"Thread {r.subject} mein {n} messages hain. Sabse naya {latest} ka hai.",
        ),
    )


def summarize_summary(r: SummarizeThreadOut, lang: str) -> str:
    line = gmail_line(r.status, lang) if r.status != "ok" else None
    if line:
        return line
    if r.via == "excerpt":
        return pick(
            lang,
            (
                f"No model is available, so here is the latest message. {r.summary}",
                f"कोई मॉडल उपलब्ध नहीं है, इसलिए सबसे नया संदेश: {r.summary}",
                f"Koi model available nahi hai, isliye sabse naya message: {r.summary}",
            ),
        )
    return r.summary


# ---------------------------------------------------------------- email writing


def draft_email_summary(r: EmailDraftOut, lang: str) -> str:
    line = gmail_line(r.status, lang) if r.status != "ok" else None
    if line:
        return line
    return pick(
        lang,
        (
            f"Draft saved in Gmail for {r.to}.",
            f"{r.to} के लिए Gmail में ड्राफ्ट सेव हो गया।",
            f"{r.to} ke liye Gmail mein draft save ho gaya.",
        ),
    )


def send_email_summary(r: SendEmailOut, lang: str) -> str:
    if r.status == "sent":
        return pick(
            lang,
            (f"Email sent to {r.to}.", f"{r.to} को ईमेल भेज दिया।", f"{r.to} ko email bhej diya."),
        )
    if r.status == "draft_mismatch":
        return pick(
            lang,
            (
                "That does not match the prepared draft, so nothing was sent.",
                "यह तैयार ड्राफ्ट से मेल नहीं खाता, इसलिए कुछ नहीं भेजा।",
                "Ye prepared draft se match nahi karta, isliye kuch nahi bheja.",
            ),
        )
    return gmail_line(r.status, lang) or ""


def send_message_summary(r: SendMessageOut, lang: str) -> str:
    if r.status == "draft_mismatch":
        return pick(
            lang,
            (
                "That does not match the prepared draft, so nothing was opened.",
                "यह तैयार ड्राफ्ट से मेल नहीं खाता, इसलिए कुछ नहीं खोला।",
                "Ye prepared draft se match nahi karta, isliye kuch nahi khola.",
            ),
        )
    app = (
        pick(lang, ("WhatsApp", "व्हाट्सऐप", "WhatsApp"))
        if r.channel == "whatsapp"
        else (pick(lang, ("Messages", "मैसेज", "Messages")))
    )
    return pick(
        lang,
        (
            f"{app} is open with your message to {r.recipient_display}. Tap send.",
            f"{app} में {r.recipient_display} के लिए आपका संदेश तैयार है। सेंड दबाएँ।",
            f"{app} mein {r.recipient_display} ke liye aapka message ready hai. Send dabao.",
        ),
    )


# ---------------------------------------------------------------- approval views (recipient + exact text)


def send_email_view(args: SendEmailIn) -> ApprovalView:
    who = f"{args.display_name} <{args.to}>" if args.display_name else args.to
    return ApprovalView(
        title=f"Send email to {who}",
        summary=args.body,
        details=(
            LabelValue(label="To", value=who),
            LabelValue(label="Subject", value=args.subject),
            LabelValue(label="Message", value=args.body),
        ),
    )


def email_draft_view(args: EmailDraftIn) -> ApprovalView:
    return ApprovalView(
        title=f"Save a Gmail draft to {args.to}",
        summary=args.body,
        details=(
            LabelValue(label="To", value=args.to),
            LabelValue(label="Subject", value=args.subject),
            LabelValue(label="Message", value=args.body),
        ),
    )


def send_message_view(args: SendMessageIn) -> ApprovalView:
    app = {"whatsapp": "WhatsApp", "sms": "SMS", "imessage": "iMessage"}[args.channel]
    who = f"{args.recipient_display}, {display_phone(args.phone)}"
    return ApprovalView(
        title=f"Prepare a {app} message to {who}",
        summary=args.text,
        details=(
            LabelValue(label="To", value=who),
            LabelValue(label="App", value=app),
            LabelValue(label="Message", value=args.text),
            LabelValue(label="Note", value="Opens the app with this text. You tap send there."),
        ),
    )
