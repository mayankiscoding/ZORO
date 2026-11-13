from __future__ import annotations

import pytest

from app.security.redaction import luhn_ok, redact_text

# All identifiers below are synthetic test values.


@pytest.mark.parametrize(
    ("text", "kind", "secret"),
    [
        ("my PAN is ABCPE1234F ok", "pan", "ABCPE1234F"),
        ("aadhaar 2345 6789 0123 please", "aadhaar", "2345 6789 0123"),
        ("aadhaar 234567890123", "aadhaar", "234567890123"),
        ("card 4111 1111 1111 1111 exp", "card", "4111 1111 1111 1111"),
        ("card 4111-1111-1111-1111", "card", "4111-1111-1111-1111"),
        ("A/c no: 001234567890 at the branch", "bank_account", "001234567890"),
        ("account number 12345678901", "bank_account", "12345678901"),
        ("IFSC HDFC0001234 branch", "ifsc", "HDFC0001234"),
        ("pay to ravi.k@okhdfcbank now", "upi", "ravi.k@okhdfcbank"),
        ("call +91 98765 43210 today", "phone", "98765 43210"),
        ("call 9876543210", "phone", "9876543210"),
        ("call 09876543210", "phone", "9876543210"),
        ("mail ravi.kumar+x@example.co.in", "email", "ravi.kumar+x@example.co.in"),
    ],
)
def test_masks_each_kind(text: str, kind: str, secret: str) -> None:
    result = redact_text(text)
    assert secret not in result.text
    assert f"[redacted:{kind}]" in result.text
    assert result.counts.get(kind) == 1
    assert result.redacted


def test_luhn() -> None:
    assert luhn_ok("4111111111111111")
    assert not luhn_ok("4111111111111112")


def test_non_luhn_long_number_is_not_called_a_card() -> None:
    result = redact_text("order 4111111111111112 shipped")
    assert "card" not in result.counts


def test_plain_text_and_amounts_untouched() -> None:
    text = "Spent ₹1,250.50 on 12 March at 5 pm; order #12345, pincode 560001."
    result = redact_text(text)
    assert result.text == text
    assert not result.redacted


def test_hindi_text_with_phone() -> None:
    result = redact_text("मेरा नंबर 9876543210 है")
    assert result.text == "मेरा नंबर [redacted:phone] है"


def test_multiple_items_counted() -> None:
    result = redact_text("a@b.com, c@d.org and 9876543210")
    assert result.counts == {"email": 2, "phone": 1}


def test_pure_and_idempotent() -> None:
    text = "PAN ABCPE1234F, phone 9876543210"
    first = redact_text(text)
    assert redact_text(text) == first
    assert redact_text(first.text).text == first.text
