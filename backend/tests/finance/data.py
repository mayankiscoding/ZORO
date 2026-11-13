"""A synthetic half-year of one owner's account (tests only), relative to 13 Nov 2026."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from tests.finance.samples import Row, generic_csv

D = Decimal


def history() -> list[Row]:
    rows: list[Row] = []
    bescom = [D("1500.00"), D("1620.00"), D("1410.00"), D("1555.00"), D("1490.00")]
    amazon = [D("1000.00"), D("1100.00"), D("950.00"), D("1050.00"), D("1000.00")]
    for i, month in enumerate(range(5, 12)):
        if month >= 6:
            rows.append(
                (date(2026, month, 1), "NEFT CR-HDFC0000001-ACME CORP-SALARY", None, None, D("100000.00"))
            )
            rows.append((date(2026, month, 5), "ACH D- NETFLIX ENTERTAINMENT", None, D("649.00"), None))
        if 6 <= month <= 10:
            ref = f"4275123457{month:02d}"
            rows.append(
                (
                    date(2026, month, 10),
                    f"UPI/DR/{ref}/BESCOM/YESB/bescom@ybl/bill",
                    None,
                    bescom[month - 6],
                    None,
                )
            )
        if month <= 9:
            rows.append((date(2026, month, 20), "ECOM PUR/AMAZON/BANGALORE", None, amazon[i], None))
    rows += [
        (date(2026, 10, 15), "UPI/DR/427512345701/SWIGGY/YESB/swiggy@ybl/Payment", None, D("800.00"), None),
        (date(2026, 11, 2), "UPI/DR/427512345702/SWIGGY/YESB/swiggy@ybl/Payment", None, D("450.00"), None),
        (date(2026, 11, 2), "UPI/DR/427512345800/SPOTIFY/YESB/spotify@ybl/Payment", None, D("119.00"), None),
        (date(2026, 11, 6), "UPI/DR/427512345703/ZOMATO/YESB/zomato@ybl/Payment", None, D("600.00"), None),
        (date(2026, 11, 8), "ECOM PUR/AMAZON/BANGALORE", None, D("9000.00"), None),
        (date(2026, 11, 9), "UPI/DR/427512345704/SWIGGY/YESB/swiggy@ybl/Payment", None, D("300.00"), None),
        (date(2026, 11, 10), "UPI/DR/427512345901/UBER/YESB/uber@ybl/Payment", None, D("250.00"), None),
        (date(2026, 11, 10), "UPI/DR/427512345902/UBER/YESB/uber@ybl/Payment", None, D("250.00"), None),
        (
            date(2026, 11, 11),
            "UPI/DR/427512345903/KUMAR STORES/SBIN/kumarstores@oksbi/Payment",
            None,
            D("75.25"),
            None,
        ),
    ]
    return sorted(rows, key=lambda r: r[0])


def history_csv() -> bytes:
    return generic_csv(history())
