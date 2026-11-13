"""Intents in English, Hindi (Devanagari) and Hinglish, with slot filling."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import pytest

from app.communications.intents import communication_intents
from app.plugins import PluginRegistry
from app.tools.intents import LANGUAGES, IntentContext

NOW = datetime(2026, 11, 13, 10, 0, tzinfo=UTC)
CTX = IntentContext(lang="en", now=NOW)
CTX_EMAILS = IntentContext(
    lang="en",
    now=NOW,
    working_sets={"emails": [{"thread_id": "a1"}, {"thread_id": "b2"}, {"thread_id": "c3"}]},
)
SPECS = {s.name: s for s in communication_intents()}

CASES: list[tuple[str, str, str, dict[str, Any]]] = [
    (
        "communications.draft_message",
        "en",
        "WhatsApp Priya saying I will be late",
        {"channel": "whatsapp", "recipient_query": "Priya", "text": "I will be late", "send": True},
    ),
    (
        "communications.draft_message",
        "en",
        "send a WhatsApp message to Priya Sharma saying I will be late",
        {"channel": "whatsapp", "recipient_query": "Priya Sharma", "text": "I will be late", "send": True},
    ),
    (
        "communications.draft_message",
        "en",
        "email hr@example.com saying I am on leave tomorrow",
        {"channel": "email", "recipient": "hr@example.com", "text": "I am on leave tomorrow", "send": True},
    ),
    (
        "communications.draft_message",
        "en",
        "send an email to Anita saying the report is ready",
        {"channel": "email", "recipient_query": "Anita", "text": "the report is ready", "send": True},
    ),
    (
        "communications.draft_message",
        "hi",
        "प्रिया को व्हाट्सऐप करो कि मैं देर से आऊँगा",
        {"channel": "whatsapp", "recipient_query": "प्रिया", "text": "मैं देर से आऊँगा", "send": True},
    ),
    (
        "communications.draft_message",
        "hi",
        "अनीता को ईमेल भेजो कि रिपोर्ट तैयार है",
        {"channel": "email", "recipient_query": "अनीता", "text": "रिपोर्ट तैयार है", "send": True},
    ),
    (
        "communications.draft_message",
        "hinglish",
        "Rahul ko whatsapp karo ki kal milte hain",
        {"channel": "whatsapp", "recipient_query": "Rahul", "text": "kal milte hain", "send": True},
    ),
    (
        "communications.draft_message",
        "hinglish",
        "Anita ko email bhejo ki report ready hai",
        {"channel": "email", "recipient_query": "Anita", "text": "report ready hai", "send": True},
    ),
    (
        "communications.find_email",
        "en",
        "find emails from Amazon about my refund",
        {"query": "from:Amazon refund"},
    ),
    ("communications.find_email", "en", "show unread emails", {"query": "is:unread"}),
    ("communications.find_email", "en", "search my email for invoice", {"query": "invoice"}),
    ("communications.find_email", "hi", "अमेज़न से आया ईमेल खोजो", {"query": "from:अमेज़न"}),
    ("communications.find_email", "hinglish", "Amazon ka email dhundo", {"query": "from:Amazon"}),
    (
        "communications.find_email",
        "hinglish",
        "mere email mein flight ticket dhundo",
        {"query": "flight ticket"},
    ),
    ("communications.read_thread", "en", "read the second email", {"ref": 2}),
    ("communications.read_thread", "hi", "पहला ईमेल पढ़ो", {"ref": 1}),
    ("communications.read_thread", "hinglish", "teesra email padho", {"ref": 3}),
    ("communications.summarize_thread", "en", "summarize the second email", {"ref": 2}),
    ("communications.summarize_thread", "hi", "दूसरे ईमेल का सारांश बताओ", {"ref": 2}),
    ("communications.summarize_thread", "hinglish", "pehle email ka summary batao", {"ref": 1}),
]


@pytest.mark.parametrize(("intent", "lang", "text", "expected"), CASES)
def test_slots(intent: str, lang: str, text: str, expected: dict[str, Any]) -> None:
    got = SPECS[intent].extract(text, CTX_EMAILS)
    assert got == expected, f"{lang}: {text!r}"
    others = [n for n, s in SPECS.items() if n != intent and s.extract(text, CTX_EMAILS) is not None]
    assert others == [], f"{text!r} also matched {others}"


def test_assumed_channel_is_flagged() -> None:
    got = SPECS["communications.draft_message"].extract("tell Rahul that I am running late", CTX)
    assert (
        got is not None
        and got["channel"] == "whatsapp"
        and got["_assumptions"] == ["channel_default_whatsapp"]
    )
    assert got["text"] == "I am running late"


def test_draft_words_ask_for_a_draft_only() -> None:
    draft = SPECS["communications.draft_message"]
    got = draft.extract("draft a WhatsApp message to Priya saying the report is ready", CTX)
    assert got is not None and got["send"] is False and got["text"] == "the report is ready"
    hindi = draft.extract("अनीता को ईमेल भेजो कि रिपोर्ट तैयार है", CTX)  # "तैयार" is in the body, not the ask
    assert hindi is not None and hindi["send"] is True


def test_missing_slots_are_reported() -> None:
    draft = SPECS["communications.draft_message"]
    assert draft.extract("whatsapp Priya", CTX) == {
        "channel": "whatsapp",
        "send": True,
        "recipient_query": "Priya",
        "_missing": ["text"],
    }
    got = draft.extract("send a message", CTX)
    assert got is not None and "recipient" in got["_missing"]


def test_reading_needs_something_shown_first() -> None:
    assert SPECS["communications.read_thread"].extract("read the second email", CTX) is None
    assert SPECS["communications.read_thread"].extract("read the fifth email", CTX_EMAILS) == {
        "_missing": ["ref"]
    }


def test_other_domains_are_not_claimed() -> None:
    for text in (
        "play Kesariya",
        "pause the music",
        "send the music to my mac",
        "what is my balance",
        "set an alarm for 7am",
        "Rahul ko call karo",
    ):
        assert all(s.extract(text, CTX_EMAILS) is None for s in SPECS.values()), text


def test_registered_with_keywords_in_three_languages(registry: PluginRegistry) -> None:
    tools = {t.name for t in registry.tools}
    intents = registry.intents.all()
    assert {i.name for i in intents} == set(SPECS)
    for spec in intents:
        assert spec.tool in tools
        assert set(spec.keywords) == set(LANGUAGES) and all(spec.keywords[lang] for lang in LANGUAGES)
        assert spec.agent.value == "communication" and spec.examples
