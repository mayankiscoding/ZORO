"""Every device tool spec matches docs/architecture/device-contract.md, and its summaries behave."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import pytest
from pydantic import ValidationError

from app.core.types import AgentId, DataClass, DevicePlatform, RiskLevel
from app.devices import tool_io as io
from app.devices.contract import ROWS, platforms_for
from app.devices.tools import device_tool_specs
from app.plugins import PluginRegistry

CONTRACT = Path(__file__).resolve().parents[3] / "docs" / "architecture" / "device-contract.md"
LANGS = ("en", "hi", "hinglish")
DEVANAGARI = re.compile(r"[ऀ-ॿ]")


def contract_table() -> dict[str, tuple[RiskLevel, DataClass]]:
    rows: dict[str, tuple[RiskLevel, DataClass]] = {}
    for line in CONTRACT.read_text(encoding="utf-8").splitlines():
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]
        if len(cells) == 6 and cells[0].startswith("`") and "." in cells[0]:
            rows[cells[0].strip("`")] = (RiskLevel(cells[3]), DataClass(cells[4]))
    return rows


def test_every_contract_row_has_a_matching_spec(registry: PluginRegistry) -> None:
    table = contract_table()
    assert len(table) == 20
    specs = {spec.name: spec for spec in device_tool_specs()}
    assert set(specs) == set(table)
    for name, (risk, data_class) in table.items():
        spec = registry.tools.get(name)
        assert spec is not None, name
        assert spec.risk is risk, name
        assert spec.data_classes == frozenset({data_class}), name
        assert spec.executor == "device" and spec.handler is None
        prefix = name.split(".")[0]
        expected = {"ios": {DevicePlatform.IOS}, "mac": {DevicePlatform.MACOS}}.get(
            prefix, {DevicePlatform.IOS, DevicePlatform.MACOS}
        )
        assert spec.device_platforms == frozenset(expected), name
        assert AgentId.DEVICE_CONTROL in spec.agents and len(spec.agents) >= 2, name
        # one health grant for the whole product, shared with the fitness package
        expected_prefix = "health." if name == "device.health.query" else "devices."
        assert spec.permission and spec.permission.startswith(expected_prefix), name
        assert spec.summarizer is not None


def test_mcp_groups() -> None:
    groups = {spec.name: spec.mcp_group for spec in device_tool_specs()}
    assert groups["device.reminder.create"] == groups["device.calendar.upcoming"] == "calendar-mcp"
    assert groups["device.location.current"] == "location-mcp"
    assert groups["device.notification.schedule"] == "notification-mcp"
    assert groups["device.photos.search"] == "ios-photos-mcp"
    assert groups["device.health.query"] == "fitness-mcp"
    assert groups["device.music.control"] == "music-mcp"
    assert groups["device.whatsapp.compose"] == groups["ios.message.compose"] == "communication-mcp"
    assert groups["ios.alarm.create"] == groups["device.open_url"] == "ios-device-mcp"
    assert {groups[n] for n in groups if n.startswith("mac.")} == {"mac-device-mcp"}
    assert {s.name for s in device_tool_specs() if AgentId.VISION in s.agents} == {"device.photos.search"}
    assert {s.name for s in device_tool_specs() if AgentId.FITNESS in s.agents} == {"device.health.query"}


def test_platforms_for_rejects_other_names() -> None:
    with pytest.raises(ValueError):
        platforms_for("finance.summary")


SAMPLE_RESULTS: dict[str, list[dict[str, Any]]] = {
    "device.reminder.create": [{"id": "r1"}],
    "device.calendar.create_event": [{"id": "e1"}],
    "device.calendar.upcoming": [
        {"events": [{"id": "e1", "title": "Standup", "start_at": "2026-11-13T09:30:00+05:30",
                     "end_at": "2026-11-13T09:45:00+05:30", "calendar": "Work"}]},
        {"events": []},
    ],
    "device.contacts.find": [
        {"matches": [{"contact_ref": "c1", "name": "Asha", "phones": ["919800000001"]}]},
        {"matches": [{"contact_ref": "c1", "name": "Asha"}, {"contact_ref": "c2", "name": "Asha K"}]},
        {"matches": []},
    ],
    "device.contacts.save": [{"contact_ref": "c9"}],
    "device.notification.schedule": [{"id": "n1"}],
    "device.location.current": [
        {"place_ref": "geo:12.97,77.64;u=15", "locality": "Indiranagar", "latitude": 12.97, "longitude": 77.64, "accuracy_m": 15},
        {"place_ref": "geo:12.97,77.64;u=15", "latitude": 12.97, "longitude": 77.64, "accuracy_m": 15},
    ],
    "device.open_url": [{"opened": True}, {"opened": False}],
    "device.shortcut.run": [{"started": True}, {"started": False}],
    "device.music.control": [{"now_playing": {"title": "Kesariya", "artist": "Arijit Singh", "provider": "apple_music"}}, {}],
    "device.photos.search": [
        {"hits": [{"asset_id": "a1", "score": 0.8, "labels": ["cap"]}], "indexed_count": 120, "limited_library": True},
        {"hits": [], "indexed_count": 0},
    ],
    "device.health.query": [
        {"points": [{"start": "2026-11-12T00:00:00+05:30", "value": 8421.0, "unit": "count"}], "sources": ["iPhone"]},
        {"points": []},
    ],
    "device.whatsapp.compose": [{"opened": True}],
    "ios.alarm.create": [{"alarm_id": "al1"}],
    "ios.timer.start": [{"timer_id": "t1"}],
    "ios.message.compose": [{"presented": True}, {"presented": True, "sent": True}, {"presented": True, "sent": False}],
    "ios.home.run_scene": [{"ran": True}, {"ran": False}],
    "mac.applescript.run": [{"output": "ok"}],
    "mac.file.search": [{"files": [{"path_ref": "docs:Budget.xlsx", "name": "Budget.xlsx"}]}, {"files": []}],
    "mac.file.open": [{"opened": True}],
}  # fmt: skip


@pytest.mark.parametrize("spec", device_tool_specs(), ids=lambda s: s.name)
def test_summaries_in_three_languages_use_only_result_values(spec: Any) -> None:
    for sample in SAMPLE_RESULTS[spec.name]:
        result = spec.output_model.model_validate(sample)
        dumped = result.model_dump_json()
        for lang in LANGS:
            text = spec.summarizer(result, lang)
            assert text and len(text) < 200 and "\n" not in text
            assert bool(DEVANAGARI.search(text)) == (lang == "hi") or spec.name == "device.health.query"
            for number in re.findall(r"\d+", text):
                assert number in dumped, (spec.name, lang, text)
        if spec.card is not None:
            card = spec.card(result)
            assert card is None or card.kind


def test_compose_tools_show_recipient_and_exact_text_for_approval() -> None:
    specs = {spec.name: spec for spec in device_tool_specs()}
    whatsapp, message = (
        specs["device.whatsapp.compose"].approval_view,
        specs["ios.message.compose"].approval_view,
    )
    assert whatsapp is not None and message is not None
    view = whatsapp(io.WhatsAppComposeIn(phone="+91 98000 00001", text="On my way"))
    assert "+919800000001" in view.title and view.summary == "On my way"
    view = message(io.MessageComposeIn(recipients=["919800000001"], body="Hi"))
    assert "+919800000001" in view.title and view.summary == "Hi"


@pytest.mark.parametrize(
    ("model", "payload"),
    [
        (io.OpenUrlIn, {"url": "http://example.com"}),
        (io.OpenUrlIn, {"url": "javascript:alert(1)"}),
        (io.OpenUrlIn, {"url": "tel:100"}),
        (io.OpenUrlIn, {"url": "https://"}),
        (io.AlarmCreateIn, {"time": "24:00"}),
        (io.AlarmCreateIn, {"time": "7:00"}),
        (io.AlarmCreateIn, {"time": "07:00", "repeat_days": ["funday"]}),
        (io.TimerStartIn, {"seconds": 0}),
        (io.TimerStartIn, {"seconds": 86401}),
        (io.MusicControlIn, {"provider": "apple_music", "action": "search_play"}),
        (io.MusicControlIn, {"provider": "youtube", "action": "play"}),
        (io.EventCreateIn, {"title": "x", "start_at": "2026-11-13T10:00:00+05:30", "end_at": "2026-11-13T09:00:00+05:30"}),
        (io.EventCreateIn, {"title": "x", "start_at": "2026-11-13T10:00:00"}),
        (io.ContactSaveIn, {"given_name": "Asha", "phone": "12345"}),
        (io.WhatsAppComposeIn, {"phone": "abc", "text": "hi"}),
        (io.MessageComposeIn, {"recipients": [], "body": "hi"}),
        (io.AppleScriptRunIn, {"script_id": "do shell script \"rm -rf\""}),
        (io.HealthQueryIn, {"metric": "steps", "from": "2026-11-13T00:00:00+05:30", "to": "2026-11-12T00:00:00+05:30"}),
        (io.ReminderCreateIn, {"title": ""}),
    ],
)  # fmt: skip
def test_invalid_arguments_are_rejected(model: Any, payload: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        model.model_validate(payload)


def test_valid_arguments_normalise() -> None:
    assert io.OpenUrlIn(url="spotify:track:1").url == "spotify:track:1"
    assert io.ContactSaveIn(given_name="Asha", phone="+91 98000-00001").phone == "919800000001"
    health = io.HealthQueryIn.model_validate(
        {"metric": "steps", "from": "2026-11-12T00:00:00+05:30", "to": "2026-11-13T00:00:00+05:30"}
    )
    assert "from" in health.model_dump(mode="json")
    upcoming = io.UpcomingIn.model_validate({"from": "2026-11-13T00:00:00+05:30", "target_platform": "macos"})
    assert upcoming.model_dump(mode="json") == {"from": "2026-11-13T00:00:00+05:30", "to": None, "limit": 5}
    assert len(ROWS) == 20
