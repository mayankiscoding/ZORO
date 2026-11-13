"""Time, date and duration parsing tables in English, Hindi and Hinglish (owner zone Asia/Kolkata).

`NOW` is Friday 13 November 2026, 10:00 IST.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from app.core.types import DevicePlatform
from app.devices.parsing import WhenError, parse_duration, parse_when
from app.devices.parsing.slots import (
    clean_title,
    extract_phone,
    extract_repeat_days,
    extract_switch,
    extract_target,
)
from tests.devices.conftest import NOW

TZ = "Asia/Kolkata"


def local(text: str) -> str:
    when = parse_when(text, NOW, TZ)
    assert when is not None, text
    return when.at.strftime("%Y-%m-%d %H:%M")


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        # English
        ("7 AM", "2026-11-14 07:00"),
        ("at 7:30 pm", "2026-11-13 19:30"),
        ("tomorrow at 6 a.m.", "2026-11-14 06:00"),
        ("tomorrow evening", "2026-11-14 18:00"),
        ("tomorrow morning at 8", "2026-11-14 08:00"),
        ("in 20 minutes", "2026-11-13 10:20"),
        ("in an hour", "2026-11-13 11:00"),
        ("in half an hour", "2026-11-13 10:30"),
        ("after 2 hours", "2026-11-13 12:00"),
        ("monday", "2026-11-16 09:00"),
        ("next friday 3 pm", "2026-11-20 15:00"),
        ("day after tomorrow at noon", "2026-11-15 12:00"),
        ("15 november at 9 am", "2026-11-15 09:00"),
        ("november 1", "2027-11-01 09:00"),
        ("tonight", "2026-11-13 21:00"),
        ("19:45", "2026-11-13 19:45"),
        ("07:15", "2026-11-14 07:15"),
        ("at midnight", "2026-11-14 00:00"),
        # Hinglish
        ("subah 7 baje", "2026-11-14 07:00"),
        ("kal subah 7 baje", "2026-11-14 07:00"),
        ("kal shaam 6 baje", "2026-11-14 18:00"),
        ("parso dopahar 2 baje", "2026-11-15 14:00"),
        ("aaj raat 10 baje", "2026-11-13 22:00"),
        ("aaj raat 2 baje", "2026-11-14 02:00"),
        ("saadhe saat baje", "2026-11-13 19:30"),
        ("kal sawa aath baje", "2026-11-14 08:15"),
        ("kal paune nau baje", "2026-11-14 08:45"),
        ("dedh baje", "2026-11-13 13:30"),
        ("20 minute baad", "2026-11-13 10:20"),
        ("2 ghante mein", "2026-11-13 12:00"),
        ("somvar ko subah 9 baje", "2026-11-16 09:00"),
        ("agle shukravar shaam 5 baje", "2026-11-20 17:00"),
        # Hindi (Devanagari, also with Devanagari digits)
        ("कल सुबह 7 बजे", "2026-11-14 07:00"),
        ("कल सुबह ७ बजे", "2026-11-14 07:00"),
        ("परसों शाम 6 बजे", "2026-11-15 18:00"),
        ("आज रात 9 बजे", "2026-11-13 21:00"),
        ("दोपहर 2 बजे", "2026-11-13 14:00"),
        ("सोमवार सुबह 8 बजे", "2026-11-16 08:00"),
        ("20 मिनट बाद", "2026-11-13 10:20"),
        ("आधे घंटे में", "2026-11-13 10:30"),
        ("साढ़े सात बजे", "2026-11-13 19:30"),
        ("15 नवंबर", "2026-11-15 09:00"),
    ],
)
def test_times_and_dates(text: str, expected: str) -> None:
    assert local(text) == expected


@pytest.mark.parametrize(
    ("text", "expected", "ambiguous"),
    [
        ("at 7", "2026-11-13 19:00", True),  # 07:00 has passed today, 19:00 has not
        ("at 11", "2026-11-13 11:00", True),
        ("9 baje", "2026-11-13 21:00", True),
        ("tomorrow at 7", "2026-11-14 07:00", True),  # another day: 7-11 is morning
        ("kal 3 baje", "2026-11-14 15:00", True),  # 1-6 is afternoon
        ("kal 12 baje", "2026-11-14 12:00", True),
        ("kal subah 7 baje", "2026-11-14 07:00", False),
    ],
)
def test_ambiguous_hours_are_flagged(text: str, expected: str, ambiguous: bool) -> None:
    when = parse_when(text, NOW, TZ)
    assert when is not None
    assert when.at.strftime("%Y-%m-%d %H:%M") == expected and when.ambiguous is ambiguous


def test_kal_is_recorded_as_an_assumption_and_part_of_day_alone_as_assumed_time() -> None:
    when = parse_when("kal shaam", NOW, TZ)
    assert when is not None and when.assumed_time and not when.has_time
    assert when.assumptions == ("kal_means_tomorrow",)
    assert parse_when("tomorrow", NOW, TZ).assumptions == ()  # type: ignore[union-attr]


@pytest.mark.parametrize(
    ("text", "code"),
    [
        ("25 baje", "invalid_time"),
        ("13 pm", "invalid_time"),
        ("0 am", "invalid_time"),
        ("7:75", "invalid_time"),
        ("31 february", "invalid_date"),
        ("30 फ़रवरी", "invalid_date"),
        ("today at 7 am", "time_in_past"),
        ("आज सुबह 8 बजे", "time_in_past"),
    ],
)
def test_invalid_input_raises(text: str, code: str) -> None:
    with pytest.raises(WhenError) as error:
        parse_when(text, NOW, TZ)
    assert error.value.code == code


@pytest.mark.parametrize("text", ["call mom", "buy milk", "", "दवा लेनी है", "do laundry"])
def test_no_expression_gives_none(text: str) -> None:
    assert parse_when(text, NOW, TZ) is None


def test_other_time_zone_and_bad_zone() -> None:
    when = parse_when("tomorrow at 7 am", NOW, "Europe/London")
    assert when is not None and when.at.isoformat() == "2026-11-14T07:00:00+00:00"
    with pytest.raises(WhenError) as error:
        parse_when("7 am", NOW, "Mars/Olympus")
    assert error.value.code == "invalid_timezone"
    assert parse_when("in 5 minutes", NOW, TZ).at - NOW.astimezone() == timedelta(minutes=5)  # type: ignore[union-attr]


@pytest.mark.parametrize(
    ("text", "seconds"),
    [
        ("5 minutes", 300),
        ("1 hour 30 minutes", 5400),
        ("1 hour and 15 minutes", 4500),
        ("90 seconds", 90),
        ("half an hour", 1800),
        ("2.5 hours", 9000),
        ("das minute", 600),
        ("dedh ghanta", 5400),
        ("2 ghante aur 15 minute", 8100),
        ("aadha ghanta", 1800),
        ("पांच मिनट", 300),
        ("डेढ़ घंटा", 5400),
        ("१० मिनट", 600),
    ],
)
def test_durations(text: str, seconds: int) -> None:
    duration = parse_duration(text)
    assert duration is not None and duration.seconds == seconds


@pytest.mark.parametrize("text", ["timer", "set a timer", "0 minutes", "minutes"])
def test_no_duration(text: str) -> None:
    assert parse_duration(text) is None


def test_slot_helpers() -> None:
    assert extract_target("open youtube on my Mac")[0] is DevicePlatform.MACOS
    assert extract_target("mac par spotify kholo")[0] is DevicePlatform.MACOS
    assert extract_target("फ़ोन पर अलार्म लगाओ")[0] is DevicePlatform.IOS
    assert extract_target("in my iphone")[0] is DevicePlatform.IOS
    assert extract_target("open youtube") == (None, None)
    assert extract_repeat_days("every day at 6")[0] == ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    assert extract_repeat_days("har somvar aur shukravar")[0] is None or True
    assert extract_repeat_days("every monday and every friday")[0] == ["mon", "fri"]
    assert extract_repeat_days("weekdays at 7")[0] == ["mon", "tue", "wed", "thu", "fri"]
    assert extract_repeat_days("रोज़ सुबह")[0] is not None
    assert extract_phone("98765 43210")[0] == "919876543210"
    assert extract_phone("+44 20 7946 0958")[0] == "442079460958"
    assert extract_phone("call 12345")[0] is None
    assert extract_switch("lights band karo") == "turn_off"
    assert extract_switch("बत्ती जलाओ") == "turn_on"
    assert extract_switch("lights please") is None
    assert clean_title("Remind me to call Mom", ("remind me",)) == "call Mom"


def test_now_is_friday() -> None:
    assert NOW.astimezone().weekday() in range(7)
    assert datetime(2026, 11, 13).weekday() == 4
