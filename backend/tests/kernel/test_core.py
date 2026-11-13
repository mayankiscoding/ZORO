"""Money maths, settings, clock, errors, ids, logging redaction."""

from __future__ import annotations

import base64
import json
import logging
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.core.clock import Clock, FixedClock, SystemClock
from app.core.errors import ApprovalExpired, KillSwitchActive, NotFound, RateLimited, ZoroError
from app.core.ids import canonical_json, new_id, new_token, sha256_hex
from app.core.logging import MASK, JsonFormatter, RedactingFilter, redact_text, redact_value
from app.core.money import (
    format_inr,
    format_inr_paise,
    from_paise,
    group_indian,
    money_from_paise,
    money_to_paise,
    percent_of_paise,
    round_money,
    sum_paise,
    to_paise,
)
from app.core.settings import Settings
from app.core.types import PrivacyMode
from app.schemas.common import ErrorBody, Money

# ---------------------------------------------------------------- money


@pytest.mark.parametrize(
    ("rupees", "paise"),
    [
        ("0", 0),
        ("1", 100),
        ("1234.50", 123450),
        ("0.01", 1),
        ("0.005", 0),  # half-even: ties go to the even paisa
        ("0.015", 2),
        ("0.025", 2),
        ("0.035", 4),
        ("2.675", 268),
        ("-0.015", -2),
        ("-1234.565", -123456),
        ("1,23,456.78", 12345678),
        ("99999999999.99", 9999999999999),
    ],
)
def test_to_paise_rounds_half_even(rupees: str, paise: int) -> None:
    assert to_paise(rupees) == paise
    assert to_paise(Decimal(rupees.replace(",", ""))) == paise


def test_paise_round_trip_is_exact() -> None:
    for paise in (0, 1, 99, 100, 123450, -5, 10**15 + 1):
        assert to_paise(from_paise(paise)) == paise
    assert from_paise(123450) == Decimal("1234.50")
    assert str(from_paise(5)) == "0.05"
    assert to_paise(7) == 700


def test_floats_bools_and_garbage_are_refused() -> None:
    with pytest.raises(TypeError):
        to_paise(1.1)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        to_paise(True)
    with pytest.raises(TypeError):
        from_paise(1.0)  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        to_paise("twelve")
    with pytest.raises(ValueError):
        to_paise(Decimal("NaN"))
    with pytest.raises(ValueError):
        to_paise("Infinity")


def test_round_money_and_percentages() -> None:
    assert round_money("2.345") == Decimal("2.34")
    assert round_money("2.355") == Decimal("2.36")
    assert round_money("1234.5", 0) == Decimal("1234")
    assert round_money("1235.5", 0) == Decimal("1236")
    assert percent_of_paise(10000, "18") == 1800
    assert percent_of_paise(105, "50") == 52  # 52.5 -> 52 (even)
    assert percent_of_paise(115, "50") == 58  # 57.5 -> 58 (even)
    assert sum_paise([1, 2, 3]) == 6
    with pytest.raises(TypeError):
        sum_paise([1, 2.5])  # type: ignore[list-item]


@pytest.mark.parametrize(
    ("amount", "text"),
    [
        ("0", "₹0.00"),
        ("5", "₹5.00"),
        ("999", "₹999.00"),
        ("1000", "₹1,000.00"),
        ("12345", "₹12,345.00"),
        ("100000", "₹1,00,000.00"),
        ("1234567.5", "₹12,34,567.50"),
        ("10000000", "₹1,00,00,000.00"),
        ("123456789012.345", "₹1,23,45,67,89,012.34"),
        ("-1234.5", "-₹1,234.50"),
        ("0.005", "₹0.00"),
    ],
)
def test_format_inr_uses_indian_grouping(amount: str, text: str) -> None:
    assert format_inr(amount) == text


def test_format_inr_options_and_money_model() -> None:
    assert format_inr("1234567.5", paise=False) == "₹12,34,568"
    assert format_inr("1234.5", symbol="Rs ") == "Rs 1,234.50"
    assert format_inr_paise(12345678) == "₹1,23,456.78"
    assert group_indian("0001234567") == "12,34,567"
    money = money_from_paise(123450)
    assert money == Money(amount=Decimal("1234.50"), currency="INR")
    assert json.loads(money.model_dump_json())["amount"] == "1234.50"  # decimal string in JSON
    assert money_to_paise(money) == 123450


# ---------------------------------------------------------------- settings


def _clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "ZORO_ENV",
        "ZORO_SECRET_KEY",
        "ZORO_DATA_KEY",
        "ZORO_DATABASE_URL",
        "ZORO_DEFAULT_PRIVACY_MODE",
    ):
        monkeypatch.delenv(name, raising=False)


def test_settings_defaults_are_safe(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _clean_env(monkeypatch)
    settings = Settings(_env_file=None, local_dir=tmp_path)
    assert settings.env == "development"
    assert settings.database_url == "sqlite+aiosqlite:///./.local/zoro.db"
    assert settings.default_privacy_mode is PrivacyMode.STRICT_PRIVATE
    assert settings.access_token_ttl_seconds == 900
    assert settings.conversation_retention_days == 30
    assert settings.object_store == "fs"
    assert settings.create_schema_on_start is True
    assert (settings.config_dir / "policy.yaml").is_file()


def test_production_refuses_to_start_without_keys(monkeypatch: pytest.MonkeyPatch) -> None:
    _clean_env(monkeypatch)
    data_key = base64.b64encode(bytes(32)).decode()
    with pytest.raises(ValidationError, match="ZORO_SECRET_KEY and ZORO_DATA_KEY"):
        Settings(_env_file=None, env="production")
    with pytest.raises(ValidationError, match="ZORO_DATA_KEY"):
        Settings(_env_file=None, env="production", secret_key="s" * 40)
    with pytest.raises(ValidationError, match="ZORO_SECRET_KEY"):
        Settings(_env_file=None, env="production", data_key=data_key)
    with pytest.raises(ValidationError, match="at least 32"):
        Settings(_env_file=None, env="production", secret_key="short", data_key=data_key)
    ok = Settings(_env_file=None, env="prod", secret_key="s" * 40, data_key=data_key)
    assert ok.is_production
    assert ok.create_schema_on_start is False
    assert ok.signing_key() == b"s" * 40
    assert ok.data_key_bytes() == bytes(32)


def test_settings_read_environment_and_reject_bad_data_key(monkeypatch: pytest.MonkeyPatch) -> None:
    _clean_env(monkeypatch)
    monkeypatch.setenv("ZORO_ENV", "test")
    monkeypatch.setenv("ZORO_DEFAULT_PRIVACY_MODE", "cloud_intelligence")
    monkeypatch.setenv("ZORO_ACCESS_TOKEN_TTL_SECONDS", "600")
    settings = Settings(_env_file=None)
    assert settings.env == "test"
    assert settings.default_privacy_mode is PrivacyMode.CLOUD_INTELLIGENCE
    assert settings.access_token_ttl_seconds == 600
    with pytest.raises(ValidationError, match="32 bytes"):
        Settings(_env_file=None, data_key=base64.b64encode(b"too short").decode())
    with pytest.raises(ValidationError):
        Settings(_env_file=None, access_token_ttl_seconds=5)


def test_generated_keys_never_come_from_source(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _clean_env(monkeypatch)
    one = Settings(_env_file=None, env="test")
    two = Settings(_env_file=None, env="test")
    assert one.signing_key() == one.signing_key()
    assert one.signing_key() != two.signing_key()  # per instance, random
    assert len(one.data_key_bytes()) == 32

    dev = Settings(_env_file=None, env="development", local_dir=tmp_path)
    again = Settings(_env_file=None, env="development", local_dir=tmp_path)
    assert dev.signing_key() == again.signing_key()  # persisted for the developer
    key_file = tmp_path / "dev-keys.json"
    assert key_file.stat().st_mode & 0o777 == 0o600
    assert "secret_key" not in repr(dev) or dev.signing_key().decode() not in repr(dev)


# ---------------------------------------------------------------- clock, ids, errors


def test_clocks() -> None:
    assert isinstance(SystemClock(), Clock)
    assert SystemClock().now().tzinfo is not None
    start = datetime(2026, 11, 13, 9, 0, tzinfo=UTC)
    clock = FixedClock(start)
    assert isinstance(clock, Clock)
    assert clock.now() == start
    clock.advance(90)
    assert clock.now() == start + timedelta(seconds=90)
    clock.advance(delta=timedelta(days=1))
    assert clock.now() == start + timedelta(days=1, seconds=90)
    with pytest.raises(ValueError):
        FixedClock(datetime(2026, 1, 1))
    with pytest.raises(ValueError):
        clock.set(datetime(2026, 1, 1))


def test_ids_and_canonical_json() -> None:
    assert new_id("txn").startswith("txn_")
    assert new_id("txn") != new_id("txn")
    assert len(new_token()) >= 43
    assert (
        canonical_json({"b": 1, "a": {"d": [1, "x"], "c": "नमस्ते"}}) == '{"a":{"c":"नमस्ते","d":[1,"x"]},"b":1}'
    )
    assert canonical_json({"a": 1, "b": 2}) == canonical_json({"b": 2, "a": 1})
    with pytest.raises(ValueError):
        canonical_json({"x": float("nan")})
    assert sha256_hex("abc") == sha256_hex(b"abc")
    assert sha256_hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"


def test_errors_map_to_error_body() -> None:
    body = NotFound("No such memory.", detail={"id": "mem_1"}).to_body()
    assert isinstance(body, ErrorBody)
    assert body.model_dump() == {
        "code": "not_found",
        "message": "No such memory.",
        "retryable": False,
        "detail": {"id": "mem_1"},
    }
    assert RateLimited().to_body().retryable is True
    assert RateLimited.status == 429
    assert KillSwitchActive().to_body().code == "kill_switch_active"
    assert ApprovalExpired.status == 410
    custom = ZoroError("x", code="special_case")
    assert custom.to_body().code == "special_case"
    assert ZoroError().to_body().code == "internal_error"
    assert ZoroError.status == 500


# ---------------------------------------------------------------- logging


def test_redact_text_masks_secret_shapes() -> None:
    samples = [
        "Authorization: Bearer abcdefghijklmnop.qrstuv",
        "token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkZXYifQ.c2lnbmF0dXJlLXZhbHVl",
        "password: hunter2hunter2",
        "PAN ABCDE1234F on file",
        "card 4111 1111 1111 1111 charged",
        "aadhaar 1234 5678 9012",
        "pay to someone@okhdfcbank now",
        "mail person@example.com",
        "call +91 9876543210",
        "otp=482913",
    ]
    for sample in samples:
        cleaned = redact_text(sample)
        assert MASK in cleaned, sample
    assert "hunter2" not in redact_text(samples[2])
    assert "4111" not in redact_text(samples[4])
    assert redact_text("spent 1,234.50 on 12 items in 2026") == "spent 1,234.50 on 12 items in 2026"


def test_redact_value_masks_sensitive_keys_recursively() -> None:
    cleaned = redact_value(
        {
            "user": "asha",
            "api_key": "k-123",
            "nested": {"Authorization": "Bearer x", "note": "PAN ABCDE1234F"},
        }
    )
    assert cleaned["user"] == "asha"
    assert cleaned["api_key"] == MASK
    assert cleaned["nested"]["Authorization"] == MASK
    assert "ABCDE1234F" not in cleaned["nested"]["note"]
    assert redact_value(b"raw-bytes") == MASK


def test_json_log_line_is_redacted() -> None:
    record = logging.LogRecord(
        "zoro.test",
        logging.INFO,
        __file__,
        1,
        "login for %s with token=%s",
        ("person@example.com", "s3cr3t"),
        None,
    )
    record.access_token = "eyJ.should.never.appear"
    record.tool = "finance.spending_summary"
    assert RedactingFilter().filter(record) is True
    line = json.loads(JsonFormatter().format(record))
    assert line["level"] == "info"
    assert line["logger"] == "zoro.test"
    assert "person@example.com" not in line["msg"]
    assert "s3cr3t" not in line["msg"]
    assert line["access_token"] == MASK
    assert line["tool"] == "finance.spending_summary"
    assert line["ts"].endswith("+00:00")
