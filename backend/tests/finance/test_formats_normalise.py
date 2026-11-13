from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from app.finance.categories import CategoryConfigSource
from app.finance.formats import AmountError, DateError, parse_amount, parse_date, signed
from app.finance.normalise import normalise
from app.finance.plugin import categories_path


@pytest.mark.parametrize(
    ("text", "value", "signed_value"),
    [
        ("1,23,456.78", "123456.78", "123456.78"),
        ("12,34,567", "1234567", "1234567"),
        ("1,234,567.00", "1234567.00", "1234567.00"),
        ("₹ 500", "500", "500"),
        ("Rs. 1,000.50", "1000.50", "1000.50"),
        ("INR 75.25", "75.25", "75.25"),
        ("500.00 Dr", "500.00", "-500.00"),
        ("2,500.00 Cr", "2500.00", "2500.00"),
        ("Dr 99.99", "99.99", "-99.99"),
        ("(1,234.00)", "1234.00", "-1234.00"),
        ("1,234.00-", "1234.00", "-1234.00"),
        ("-450.50", "450.50", "-450.50"),
        ("+2,000.00", "2000.00", "2000.00"),
        (".50", "0.50", "0.50"),
    ],
)
def test_indian_amounts(text: str, value: str, signed_value: str) -> None:
    parsed = parse_amount(text)
    assert parsed is not None
    assert parsed.value == Decimal(value) and isinstance(parsed.value, Decimal)
    assert signed(parsed) == Decimal(signed_value)


@pytest.mark.parametrize("text", ["", "  ", "-", "--", "NA", "nil"])
def test_blank_amounts(text: str) -> None:
    assert parse_amount(text) is None


@pytest.mark.parametrize("text", ["abc", "1,23", "12.3.4", "1.2x", "₹"])
def test_bad_amounts(text: str) -> None:
    with pytest.raises(AmountError):
        parse_amount(text)


def test_floats_refused() -> None:
    with pytest.raises(AmountError):
        parse_amount(12.5)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("03/10/2026", date(2026, 10, 3)),
        ("03/10/26", date(2026, 10, 3)),
        ("03-10-2026", date(2026, 10, 3)),
        ("03.10.2026", date(2026, 10, 3)),
        ("03-Oct-26", date(2026, 10, 3)),
        ("03-OCT-2026", date(2026, 10, 3)),
        ("3 Oct 2026", date(2026, 10, 3)),
        ("03 October 2026", date(2026, 10, 3)),
        ("Oct 3, 2026", date(2026, 10, 3)),
        ("2026-10-03", date(2026, 10, 3)),
        ("2026-10-03T14:05:00", date(2026, 10, 3)),
        ("03/10/2026 13:05:22", date(2026, 10, 3)),
        ("03/10/2026 01:05 PM", date(2026, 10, 3)),
    ],
)
def test_dates_day_first(text: str, expected: date) -> None:
    assert parse_date(text) == expected


@pytest.mark.parametrize("text", ["32/13/2026", "hello", "2026-02-30", "", "Opening Balance"])
def test_bad_dates(text: str) -> None:
    with pytest.raises(DateError):
        parse_date(text)


ALIASES = CategoryConfigSource(categories_path(None)).current().merchants


@pytest.mark.parametrize(
    ("narration", "merchant", "channel", "vpa", "ref"),
    [
        ("UPI/DR/427512345601/SWIGGY/YESB/swiggy@ybl/Payment", "Swiggy", "upi", "swiggy@ybl", "427512345601"),
        ("UPI-SWIGGY-SWIGGY@YBL-YESB0YBLUPI-427512345601-PAYMENT FROM PHONE", "Swiggy", "upi", "swiggy@ybl",
         "427512345601"),
        ("UPI/427512345602/Payment/zomato@hdfcbank/HDFC BANK/AXIS", "Zomato", "upi", "zomato@hdfcbank", "427512345602"),
        ("UPI/P2M/427512345603/BLINKIT/Payment/YES BANK", "Blinkit", "upi", None, "427512345603"),
        ("UPI/427512345604/Payment/9876543210@ybl/SBI", "UPI payee ••3210", "upi", "••3210@ybl", "427512345604"),
        ("TO TRANSFER-UPI/DR/427512345605/RAHUL KUMAR/SBIN/rahulk@oksbi/rent", "Rahul Kumar", "upi", "rahulk@oksbi",
         "427512345605"),
        ("UPI/DR/427512345606/swiggy.instamart@icici", "Swiggy Instamart", "upi", "swiggy.instamart@icici",
         "427512345606"),
        ("POS 416021XXXXXX1234 SWIGGY BANGALORE", "Swiggy", "card", None, None),
        ("ECOM PUR/AMAZON PAY INDIA/BANGALORE", "Amazon", "card", None, None),
        ("NEFT/N123456789012/ACME CORP/HDFC0001234", "Acme Corp", "neft", None, "N123456789012"),
        ("NEFT CR-HDFC0000001-ACME CORP-SALARY OCT", "Acme Corp", "neft", None, None),
        ("MMT/IMPS/427512345607/RAHUL K/SBIN0001234", "Rahul K", "imps", None, "427512345607"),
        ("ATM WDL/416021XXXXXX1234/MG ROAD", "ATM withdrawal", "atm", None, None),
        ("NWD-416021XXXXXX1234-S1AW0001-BANGALORE", "ATM withdrawal", "atm", None, None),
        ("BY CASH DEPOSIT", "Cash deposit", "cash", None, None),
        ("ACH D- NETFLIX ENTERTAINMENT", "Netflix", "other", None, None),
    ],
)  # fmt: skip
def test_merchant_normalisation(
    narration: str, merchant: str, channel: str, vpa: str | None, ref: str | None
) -> None:
    n = normalise(narration, ALIASES)
    assert (n.merchant, n.channel, n.vpa, n.upi_ref) == (merchant, channel, vpa, ref)
