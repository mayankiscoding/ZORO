"""Device intents: keywords in three languages and slot extraction."""

from __future__ import annotations

from typing import Any

import pytest

from app.devices.homeassistant import HAEntity, HomeAssistantConfig
from app.devices.intents import device_intents
from app.tools.intents import LANGUAGES, IntentContext, IntentRegistry
from tests.devices.conftest import NOW

HA = HomeAssistantConfig(
    "http://ha.local:8123",
    "test-token",
    (
        HAEntity("light.bedroom", "Bedroom", ("sone ka kamra", "बेडरूम")),
        HAEntity("light.living_room", "Living room", ("baithak",)),
        HAEntity("switch.fan", "Fan"),
    ),
)
INTENTS = {spec.name: spec for spec in device_intents(lambda: HA)}
CTX = IntentContext(lang="en", now=NOW, timezone="Asia/Kolkata")


def run(name: str, text: str) -> dict[str, Any] | None:
    return INTENTS[name].extract(text, CTX)


def test_registration_and_keywords() -> None:
    registry = IntentRegistry()
    for spec in INTENTS.values():
        registry.register(spec)
        assert set(spec.keywords) == set(LANGUAGES), spec.name
        assert all(spec.keywords[lang] for lang in LANGUAGES), spec.name
        assert spec.agent.value == "device_control"
    assert len(registry) == 9


@pytest.mark.parametrize(
    ("text", "slots"),
    [
        ("set an alarm for 6:30 am", {"time": "06:30"}),
        ("wake me up at 7 tomorrow", {"time": "07:00", "_ambiguous": True}),
        ("subah 6 baje ka alarm laga do", {"time": "06:00"}),
        ("कल सुबह 7 बजे का अलार्म लगा दो", {"time": "07:00", "_assumptions": ["kal_means_tomorrow"]}),
        ("har somvar subah 7 baje alarm lagao", {"time": "07:00", "repeat_days": ["mon"]}),
        ("set a gym alarm for 5 am every day", {"time": "05:00", "label": "gym",
                                                 "repeat_days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]}),
        ("set an alarm on my iphone for 6 am", {"time": "06:00", "_target_platform": "ios"}),
        ("set an alarm", {"_missing": ["time"]}),
        ("alarm for 25 baje", {"_missing": ["time"], "_problem": "invalid_time"}),
    ],
)  # fmt: skip
def test_alarm(text: str, slots: dict[str, Any]) -> None:
    assert run("devices.set_alarm", text) == slots


@pytest.mark.parametrize(
    ("text", "slots"),
    [
        ("start a 10 minute timer", {"seconds": 600}),
        ("set a timer for 1 hour 30 minutes", {"seconds": 5400}),
        ("pasta ke liye das minute ka timer lagao", {"seconds": 600, "label": "pasta"}),
        ("5 मिनट का टाइमर लगाओ", {"seconds": 300}),
        ("डेढ़ घंटे का टाइमर", {"seconds": 5400}),
        ("start a timer", {"_missing": ["seconds"]}),
    ],
)
def test_timer(text: str, slots: dict[str, Any]) -> None:
    assert run("devices.start_timer", text) == slots


@pytest.mark.parametrize(
    ("text", "title", "due"),
    [
        ("remind me to call mom tomorrow at 7 pm", "call mom", "2026-11-14T19:00:00+05:30"),
        ("remind me in 20 minutes to check the oven", "check the oven", "2026-11-13T10:20:00+05:30"),
        ("remind me to do laundry", "do laundry", None),
        ("remind me to buy a gift for Asha on Monday", "buy a gift for Asha", "2026-11-16T09:00:00+05:30"),
        ("kal subah 7 baje mujhe doodh lene ki yaad dilana", "doodh lene", "2026-11-14T07:00:00+05:30"),
        ("20 minute baad chai banane ka reminder lagao", "chai banane", "2026-11-13T10:20:00+05:30"),
        ("कल सुबह 7 बजे मुझे दवा लेने की याद दिलाना", "दवा लेने", "2026-11-14T07:00:00+05:30"),
        ("परसों शाम 6 बजे बिल भरने का रिमाइंडर लगा दो", "बिल भरने", "2026-11-15T18:00:00+05:30"),
    ],
)
def test_reminder(text: str, title: str, due: str | None) -> None:
    slots = run("devices.create_reminder", text)
    assert slots is not None and slots["title"] == title
    assert slots.get("due_at") == due


def test_reminder_edge_cases() -> None:
    assert run("devices.create_reminder", "remind me tomorrow") == {"_missing": ["title"]} | {
        "due_at": "2026-11-14T09:00:00+05:30"
    }
    assert run("devices.create_reminder", "remind me to pay rent today at 7 am") == {
        "title": "pay rent", "_problem": "time_in_past",
    }  # fmt: skip
    assert run("devices.create_reminder", "call mom") is None


def test_calendar() -> None:
    assert run("devices.next_meeting", "when is my next meeting") == {
        "from": "2026-11-13T10:00:00+05:30",
        "limit": 1,
    }
    today = run("devices.next_meeting", "aaj ki meetings batao")
    assert today == {"from": "2026-11-13T10:00:00+05:30", "to": "2026-11-14T00:00:00+05:30", "limit": 10}
    tomorrow = run("devices.next_meeting", "कल की मीटिंग")
    assert tomorrow is not None and tomorrow["from"] == "2026-11-14T00:00:00+05:30"
    event = run("devices.create_event", "schedule a meeting with Rahul tomorrow at 3 pm for 30 minutes")
    assert event == {
        "start_at": "2026-11-14T15:00:00+05:30", "end_at": "2026-11-14T15:30:00+05:30", "title": "meeting with Rahul",
    }  # fmt: skip
    hinglish = run("devices.create_event", "kal shaam 5 baje dentist appointment calendar mein add karo")
    assert hinglish is not None and hinglish["start_at"] == "2026-11-14T17:00:00+05:30"
    assert hinglish["title"] == "dentist appointment"
    hindi = run("devices.create_event", "सोमवार सुबह 10 बजे टीम मीटिंग कैलेंडर में जोड़ दो")
    assert (
        hindi is not None
        and hindi["start_at"] == "2026-11-16T10:00:00+05:30"
        and hindi["title"] == "टीम मीटिंग"
    )
    assert run("devices.create_event", "add a meeting") == {"_missing": ["start_at"], "title": "meeting"}
    assert run("devices.create_event", "when is my next meeting") is None


@pytest.mark.parametrize(
    ("text", "slots"),
    [
        ("save Rahul's number 98765 43210", {"phone": "919876543210", "given_name": "Rahul"}),
        ("Rahul Sharma ka number 9876543210 save karo",
         {"phone": "919876543210", "given_name": "Rahul", "family_name": "Sharma"}),
        ("राहुल का नंबर 9876543210 सेव करो", {"phone": "919876543210", "given_name": "राहुल"}),
        ("add contact Asha asha@example.com", {"email": "asha@example.com", "given_name": "Asha"}),
        ("save this number 9876543210", {"phone": "919876543210", "given_name": "this"}),
    ],
)  # fmt: skip
def test_save_contact(text: str, slots: dict[str, Any]) -> None:
    assert run("devices.save_contact", text) == slots


def test_shortcut_and_open() -> None:
    assert run("devices.run_shortcut", "run my Good Morning shortcut") == {"name": "Good Morning"}
    assert run("devices.run_shortcut", "शॉर्टकट Office Mode चलाओ") == {"name": "Office Mode"}
    assert run("devices.run_shortcut", "run shortcut") == {"_missing": ["name"]}
    assert run("devices.open", "open youtube on my mac") == {
        "_target_platform": "macos",
        "url": "https://www.youtube.com",
    }
    assert run("devices.open", "example.com kholo") == {"url": "https://example.com"}
    assert run("devices.open", "open https://zoro.example/docs?a=1") == {
        "url": "https://zoro.example/docs?a=1"
    }
    assert run("devices.open", "स्पॉटिफ़ाई खोलो") == {"url": "spotify:"}
    assert run("devices.open", "open the file budget") is None
    assert run("devices.open", "open sesame") == {"_missing": ["url"]}


@pytest.mark.parametrize(
    ("text", "service", "entities", "extra"),
    [
        ("turn off the bedroom lights", "turn_off", ["light.bedroom"], {}),
        ("turn on the lights", "turn_on", ["light.bedroom", "light.living_room"], {}),
        ("baithak ki light on karo 40%", "turn_on", ["light.living_room"], {"brightness_pct": 40}),
        ("बेडरूम की बत्ती बंद करो", "turn_off", ["light.bedroom"], {}),
    ],
)
def test_lights(text: str, service: str, entities: list[str], extra: dict[str, Any]) -> None:
    slots = run("devices.lights", text)
    assert slots == {"domain": "light", "service": service, "entity_ids": entities, **extra}


def test_lights_not_matched() -> None:
    assert run("devices.lights", "is the light on?") is None
    assert run("devices.lights", "lights") is None
    unconfigured = device_intents(lambda: HomeAssistantConfig(None, None))
    lights = next(s for s in unconfigured if s.name == "devices.lights")
    assert lights.extract("lights off", CTX) == {"domain": "light", "service": "turn_off", "entity_ids": []}
