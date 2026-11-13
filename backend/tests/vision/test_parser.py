"""Photo-query parsing table: English, Hindi, Hinglish, with a fixed clock (Friday 13 Nov 2026, 12:00 IST)."""

from __future__ import annotations

from datetime import UTC, date, datetime
from typing import Any

import pytest

from app.vision.parser import parse_photo_query

NOW = datetime(2026, 11, 13, 6, 30, tzinfo=UTC)
D = date


def q(text: str, now: datetime = NOW, tz: str = "Asia/Kolkata") -> dict[str, Any]:
    return parse_photo_query(text, now, tz).query.model_dump(exclude={"text"})


def expect(**fields: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "date_from": None,
        "date_to": None,
        "colors": [],
        "labels": [],
        "contains_text": None,
        "media": "any",
        "limit": 30,
    }
    base.update(fields)
    return base


YESTERDAY = {"date_from": D(2026, 11, 12), "date_to": D(2026, 11, 12)}
LAST_MONTH = {"date_from": D(2026, 10, 1), "date_to": D(2026, 10, 31)}
LAST_WEEK = {"date_from": D(2026, 11, 2), "date_to": D(2026, 11, 8)}

TABLE: list[tuple[str, dict[str, Any]]] = [
    # --- the contract example
    ("photo from yesterday with my blue cap", expect(**YESTERDAY, colors=["blue"], labels=["cap", "hat"])),
    # --- English
    ("show me photos from last month", expect(**LAST_MONTH)),
    ("pictures from last week of my dog", expect(**LAST_WEEK, labels=["dog", "puppy"])),
    ("photos from today", expect(date_from=D(2026, 11, 13), date_to=D(2026, 11, 13))),
    ("photos from the day before yesterday", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 11))),
    ("pics from 3 days ago", expect(date_from=D(2026, 11, 10), date_to=D(2026, 11, 10))),
    ("photos from the last 3 days", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 13))),
    ("photos from this week", expect(date_from=D(2026, 11, 9), date_to=D(2026, 11, 13))),
    ("photos from this month", expect(date_from=D(2026, 11, 1), date_to=D(2026, 11, 13))),
    ("photos from last year", expect(date_from=D(2025, 1, 1), date_to=D(2025, 12, 31))),
    ("photos from 2 weeks ago", expect(date_from=D(2026, 10, 26), date_to=D(2026, 11, 1))),
    ("photos from 2 months ago", expect(date_from=D(2026, 9, 1), date_to=D(2026, 9, 30))),
    ("photos from last weekend", expect(date_from=D(2026, 11, 7), date_to=D(2026, 11, 8))),
    ("photos from last friday", expect(date_from=D(2026, 11, 6), date_to=D(2026, 11, 6))),
    ("photos from monday", expect(date_from=D(2026, 11, 9), date_to=D(2026, 11, 9))),
    ("photos from 5 march", expect(date_from=D(2026, 3, 5), date_to=D(2026, 3, 5))),
    ("photos from march 5th 2025", expect(date_from=D(2025, 3, 5), date_to=D(2025, 3, 5))),
    ("photos from december", expect(date_from=D(2025, 12, 1), date_to=D(2025, 12, 31))),
    ("photos from november", expect(date_from=D(2026, 11, 1), date_to=D(2026, 11, 13))),
    ("photos from March 2026", expect(date_from=D(2026, 3, 1), date_to=D(2026, 3, 31))),
    ("photos from 2026-11-11", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 11))),
    ("photos from 11/11/2026", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 11))),
    ("my red car photos", expect(colors=["red"], labels=["car", "vehicle"])),
    ("green shoes", expect(colors=["green"], labels=["shoe", "sneaker", "footwear"])),
    ("black and white photos of a cat", expect(colors=["black", "white"], labels=["cat", "kitten"])),
    ("show 5 photos of the beach", expect(labels=["beach", "sea", "sand"], limit=5)),
    ("last 10 photos", expect(limit=10)),
    ("screenshots from yesterday", expect(**YESTERDAY, media="screenshot")),
    (
        "only photos not screenshots from today",
        expect(date_from=D(2026, 11, 13), date_to=D(2026, 11, 13), media="photo"),
    ),
    (
        "screenshot of a receipt from last week",
        expect(**LAST_WEEK, media="screenshot", labels=["document", "receipt"]),
    ),
    ("scanned document", expect(labels=["document"])),
    ("my aadhaar card photo", expect(labels=["document", "id card"])),
    (
        'screenshot that says "OTP 4821" from yesterday',
        expect(**YESTERDAY, media="screenshot", contains_text="OTP 4821"),
    ),
    (
        "photo with text invoice number from last month",
        expect(**LAST_MONTH, contains_text="invoice number", labels=["document", "receipt"]),
    ),
    ("sunset photos", expect(labels=["sunset", "sky"])),
    (
        "pictures of my family at the temple",
        expect(labels=["people", "family", "temple", "building", "statue"]),
    ),
    ("photos", expect()),
    # --- Hindi
    ("कल की फोटो", expect(**YESTERDAY)),
    ("पिछले महीने की तस्वीरें", expect(**LAST_MONTH)),
    ("पिछले हफ़्ते की फ़ोटो", expect(**LAST_WEEK)),
    ("आज की तस्वीरें", expect(date_from=D(2026, 11, 13), date_to=D(2026, 11, 13))),
    ("परसों की फोटो", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 11))),
    ("नीली टोपी वाली फोटो कल की", expect(**YESTERDAY, colors=["blue"], labels=["cap", "hat"])),
    ("लाल गाड़ी की तस्वीरें", expect(colors=["red"], labels=["car", "vehicle"])),
    ("काले कुत्ते की फोटो", expect(colors=["black"], labels=["dog", "puppy"])),
    ("सफेद साड़ी में फोटो", expect(colors=["white"], labels=["dress", "clothing"])),
    ("पीली शर्ट वाली तस्वीर", expect(colors=["yellow"], labels=["shirt", "t-shirt", "clothing"])),
    ("पिछले 3 दिनों की फोटो", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 13))),
    ("2 दिन पहले की फोटो", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 11))),
    ("5 मार्च की तस्वीरें", expect(date_from=D(2026, 3, 5), date_to=D(2026, 3, 5))),
    ("पिछले साल की फोटो", expect(date_from=D(2025, 1, 1), date_to=D(2025, 12, 31))),
    ("समुद्र की 5 फोटो", expect(labels=["beach", "sea", "sand"], limit=5)),
    ("स्क्रीनशॉट कल के", expect(**YESTERDAY, media="screenshot")),
    ("रसीद का स्क्रीनशॉट", expect(media="screenshot", labels=["document", "receipt"])),
    (
        "जिसमें बिल नंबर लिखा हो वो स्क्रीनशॉट",
        expect(media="screenshot", contains_text="बिल नंबर", labels=["document", "receipt"]),
    ),
    ("पिछले शुक्रवार की फोटो", expect(date_from=D(2026, 11, 6), date_to=D(2026, 11, 6))),
    # --- Hinglish
    ("kal ki photo", expect(**YESTERDAY)),
    ("pichhle mahine ki tasveer", expect(**LAST_MONTH)),
    ("pichle hafte ki photos", expect(**LAST_WEEK)),
    ("aaj ki photos", expect(date_from=D(2026, 11, 13), date_to=D(2026, 11, 13))),
    ("parso ki photo", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 11))),
    ("kal ki neeli topi wali photo", expect(**YESTERDAY, colors=["blue"], labels=["cap", "hat"])),
    ("laal gaadi ki photo", expect(colors=["red"], labels=["car", "vehicle"])),
    ("kale kutte ki photos", expect(colors=["black"], labels=["dog", "puppy"])),
    (
        "safed jooton ki photo",
        expect(colors=["white"]),
    ),  # "jooton" is not in the lexicon: no object is guessed
    ("safed joote ki photo", expect(colors=["white"], labels=["shoe", "sneaker", "footwear"])),
    ("hari shirt wali photo", expect(colors=["green"], labels=["shirt", "t-shirt", "clothing"])),
    ("gulabi phool ki photos", expect(colors=["pink"], labels=["flower", "plant"])),
    ("pichhle 3 din ki photos", expect(date_from=D(2026, 11, 11), date_to=D(2026, 11, 13))),
    ("3 din pehle ki photo", expect(date_from=D(2026, 11, 10), date_to=D(2026, 11, 10))),
    ("5 march ki photos", expect(date_from=D(2026, 3, 5), date_to=D(2026, 3, 5))),
    ("pichhle saal ki photos", expect(date_from=D(2025, 1, 1), date_to=D(2025, 12, 31))),
    ("dikhao 10 photo samundar ki", expect(labels=["beach", "sea", "sand"], limit=10)),
    ("screenshot kal ka", expect(**YESTERDAY, media="screenshot")),
    ("screenshot nahi sirf photos", expect(media="photo")),
    ("pichhle shukravar ki photo", expect(date_from=D(2026, 11, 6), date_to=D(2026, 11, 6))),
    (
        "receipt ka screenshot pichhle hafte ka",
        expect(**LAST_WEEK, media="screenshot", labels=["document", "receipt"]),
    ),
]


@pytest.mark.parametrize(("text", "want"), TABLE, ids=[t for t, _ in TABLE])
def test_parsing_table(text: str, want: dict[str, Any]) -> None:
    got = q(text)
    assert got == want, got


def test_text_keeps_the_owners_sentence() -> None:
    parsed = parse_photo_query("  photo from yesterday with my blue cap ", NOW)
    assert parsed.query.text == "photo from yesterday with my blue cap"
    assert len(parse_photo_query("x" * 900, NOW).query.text) == 500


def test_kal_is_yesterday_and_says_so() -> None:
    for text in ("kal ki photo", "कल की फोटो"):
        assert "yesterday" in " ".join(parse_photo_query(text, NOW).assumptions)
    assert parse_photo_query("photo from yesterday", NOW).assumptions == ()


def test_assumptions_for_year_weekday_and_weeks() -> None:
    assert "most recent" in " ".join(parse_photo_query("photos from 5 march", NOW).assumptions)
    assert "Friday" in " ".join(parse_photo_query("photos from friday", NOW).assumptions)
    assert "Monday to Sunday" in " ".join(parse_photo_query("photos from 2 weeks ago", NOW).assumptions)
    assert "day first" in " ".join(parse_photo_query("photos from 11/11/2026", NOW).assumptions)


def test_dates_follow_the_owners_time_zone() -> None:
    late = datetime(2026, 11, 12, 20, 0, tzinfo=UTC)  # 01:30 on 13 Nov in India, still 12 Nov in UTC
    assert q("photos from today", late, "Asia/Kolkata")["date_from"] == D(2026, 11, 13)
    assert q("photos from today", late, "UTC")["date_from"] == D(2026, 11, 12)
    assert q("photos from yesterday", late, "America/Los_Angeles")["date_from"] == D(2026, 11, 11)
    unknown = parse_photo_query("photos from today", late, "Mars/Olympus")
    assert unknown.query.date_from == D(2026, 11, 13) and "Asia/Kolkata" in " ".join(unknown.assumptions)


def test_year_boundaries_and_future_guard() -> None:
    jan = datetime(2026, 1, 10, 6, 0, tzinfo=UTC)
    assert q("photos from december", jan)["date_from"] == D(2025, 12, 1)
    assert q("photos from last month", jan) == expect(date_from=D(2025, 12, 1), date_to=D(2025, 12, 31)) | {
        "colors": [],
        "labels": [],
    }
    assert q("photos from last year", jan)["date_to"] == D(2025, 12, 31)
    assert q("photos from 25 december", jan)["date_from"] == D(2025, 12, 25)
    leap = datetime(2028, 3, 1, 6, 0, tzinfo=UTC)
    assert q("photos from 29 february", leap)["date_from"] == D(2028, 2, 29)


def test_invalid_or_ambiguous_dates_are_not_guessed() -> None:
    for text in ("photos from 31 february 2026", "photos from 45/13/2026", "may I see my photos"):
        got = q(text)
        assert got["date_from"] is None and got["date_to"] is None, text
    assert q("photos from may 2025")["date_from"] == D(2025, 5, 1)
    assert q("photos in may")["date_from"] == D(2026, 5, 1)


def test_limit_is_bounded() -> None:
    assert q("show 500 photos")["limit"] == 200
    assert "200" in " ".join(parse_photo_query("show 500 photos", NOW).assumptions)
    assert q("show 0 photos")["limit"] == 30
    assert q("photos from the last 3 days")["limit"] == 30  # "3 days" is a date, not a count


def test_an_empty_filter_query_is_still_valid() -> None:
    parsed = parse_photo_query("photos", NOW)
    assert not parsed.query.is_filtered and parsed.matched == {}
    assert parse_photo_query("blue cap", NOW).query.is_filtered


def test_quoted_text_keeps_its_case_and_single_quotes_are_handled() -> None:
    assert q('screenshot with "Flight PNR AB12CD"')["contains_text"] == "Flight PNR AB12CD"
    assert q("screenshot of 'Hello World' message")["contains_text"] == "Hello World"
    assert q("don't show screenshots")["contains_text"] is None  # an apostrophe is not a quote
    assert q("photo that reads welcome home from last week")["contains_text"] == "welcome home"
