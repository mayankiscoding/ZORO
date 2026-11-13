from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from app.finance.mapping import check_balances, detect_header, parse_rows
from app.finance.readers import (
    CsvReader,
    PdfReader,
    StatementReadError,
    XlsxReader,
    read_statement,
    read_text,
)
from tests.finance.samples import hdfc_csv, paytm_csv, ruled_pdf, sbi_xlsx, xl_date

D = Decimal
HDFC_ROWS = [
    (date(2026, 10, 1), "NEFT CR-HDFC0000001-ACME CORP-SALARY OCT", "N123456789012", None, D("100000.00")),
    (date(2026, 10, 3), "UPI-SWIGGY-SWIGGY@YBL-YESB0YBLUPI-427512345601-PAYMENT FROM PHONE", "0000427512345601",
     D("450.50"), None),
    (date(2026, 10, 5), "POS 416021XXXXXX1234 DMART BANGALORE", None, D("2345.75"), None),
    (date(2026, 10, 9), "ATM WDL/416021XXXXXX1234/MG ROAD", None, D("5000.00"), None),
]  # fmt: skip


def test_hdfc_csv_profile_and_balances() -> None:
    table = CsvReader().read(hdfc_csv(HDFC_ROWS, D("50000.00")))
    stmt = parse_rows(table.rows)
    assert stmt.header is not None and stmt.header.profile == "hdfc_bank"
    assert [r.amount for r in stmt.rows] == [D("100000.00"), D("450.50"), D("2345.75"), D("5000.00")]
    assert [r.direction for r in stmt.rows] == ["credit", "debit", "debit", "debit"]
    assert stmt.opening == D("50000.00") and stmt.closing == D("142203.75")
    assert stmt.rows[1].balance == D("149549.50")
    assert check_balances(stmt).status == "ok"
    assert [s.reason for s in stmt.skipped] == ["summary row"]


def test_balance_mismatch_is_reported() -> None:
    data = hdfc_csv(HDFC_ROWS, D("50000.00")).replace(b"1,49,549.50", b"1,49,500.50")
    stmt = parse_rows(CsvReader().read(data).rows)
    check = check_balances(stmt)
    assert check.status == "mismatch" and "running balance" in check.detail


def test_descending_statement_running_balance_ok() -> None:
    table = CsvReader().read(hdfc_csv(HDFC_ROWS, D("50000.00")))
    header_at = next(i for i, r in enumerate(table.rows) if r and r[0] == "Date")
    body = [r for r in table.rows[header_at + 1 :] if r and r[0][:1].isdigit()]
    stmt = parse_rows([table.rows[header_at], *reversed(body)])
    assert check_balances(stmt).status == "ok"


def test_malformed_rows_are_reported_not_imported() -> None:
    extra = [
        ["32/13/26", "BAD DATE ROW", "", "", "10.00", "", "1.00"],
        ["10/10/26", "BOTH SIDES", "", "", "10.00", "20.00", "1.00"],
        ["11/10/26", "NO AMOUNT", "", "", "", "", ""],
        ["12/10/26", "GARBAGE AMOUNT", "", "", "ten", "", "1.00"],
    ]
    stmt = parse_rows(CsvReader().read(hdfc_csv(HDFC_ROWS, D("50000.00"), extra=extra)).rows)
    assert len(stmt.rows) == 4
    reasons = sorted(e.reason for e in stmt.errors)
    assert reasons == ["both debit and credit are filled", "invalid date", "no amount", "not an amount"]


def test_sbi_xlsx_with_excel_numbers_and_dates() -> None:
    data = sbi_xlsx([
        [xl_date(date(2026, 10, 2)), xl_date(date(2026, 10, 2)), "UPI/DR/427512345611/ZOMATO/YESB/zomato@ybl/Pay",
         "", 349.9, None, 9650.1],
        [xl_date(date(2026, 10, 4)), xl_date(date(2026, 10, 4)), "BY TRANSFER-NEFT/ACME CORP", "", None, 1234.56, 10884.66],
        ["not a date", "", "junk", "", 1, None, 1],
    ])  # fmt: skip
    table = XlsxReader().read(data)
    stmt = parse_rows(table.rows)
    assert stmt.header is not None and stmt.header.profile == "sbi"
    assert [(r.txn_date, r.amount, r.direction) for r in stmt.rows] == [
        (date(2026, 10, 2), D("349.9"), "debit"),
        (date(2026, 10, 4), D("1234.56"), "credit"),
    ]
    assert all(isinstance(r.amount, Decimal) for r in stmt.rows)
    assert [e.reason for e in stmt.errors] == ["invalid date"]
    assert check_balances(stmt).status == "ok"


def test_ruled_pdf_table() -> None:
    rows = [
        ["Tran Date", "CHQNO", "PARTICULARS", "DR", "CR", "BAL"],
        ["01-11-2026", "", "UPI/P2M/430612345601/BLINKIT/Payment", "612.00", "", "19,388.00"],
        ["02-11-2026", "", "NEFT/N987654321099/ACME CORP/HDFC0001234", "", "25,000.00", "44,388.00"],
        ["03-11-2026", "", "ECOM PUR/AMAZON PAY INDIA/BANGALORE", "1,499.00", "", "42,889.00"],
    ]
    data = ruled_pdf(rows, [60, 40, 230, 60, 60, 70], title="Axis Bank synthetic statement")
    table = PdfReader().read(data)
    stmt = parse_rows(table.rows)
    assert stmt.header is not None and stmt.header.profile == "axis_bank"
    assert [(r.narration[:11], r.amount, r.direction) for r in stmt.rows] == [
        ("UPI/P2M/430", D("612.00"), "debit"),
        ("NEFT/N98765", D("25000.00"), "credit"),
        ("ECOM PUR/AM", D("1499.00"), "debit"),
    ]
    assert check_balances(stmt).status == "ok"


def test_pdf_without_text_and_unknown_files_fail_cleanly() -> None:
    with pytest.raises(StatementReadError):
        PdfReader().read(b"%PDF-1.4\nnot really a pdf")
    with pytest.raises(StatementReadError):
        read_statement("old.xls", b"\xd0\xcf\x11\xe0" + b"\x00" * 64)
    with pytest.raises(StatementReadError):
        read_statement("empty.csv", b"")


OCR_TEXT = """Statement of Account
Opening Balance 10,000.00
Date Narration Withdrawal Deposit Balance
02/11/2026 UPI/DR/430612345678/ZOMATO/YESB/zomato@ybl/Payment 350.00 9,650.00
03/11/2026 NEFT/N987654321012/ACME CORP/HDFC0001234 5,000.00 14,650.00
04 Nov 2026 ATM WDL/416021XXXXXX1234/MG ROAD 2,000.00 12,650.00
Closing Balance 12,650.00
"""


def test_ocr_text_single_spaced_infers_columns_from_balance() -> None:
    table = read_text(OCR_TEXT)
    stmt = parse_rows(table.rows, text_rows=table.text_rows)
    assert stmt.header is not None and stmt.header.profile == "generic"
    assert [(r.txn_date.day, r.amount, r.direction) for r in stmt.rows] == [
        (2, D("350.00"), "debit"),
        (3, D("5000.00"), "credit"),
        (4, D("2000.00"), "debit"),
    ]
    assert stmt.opening == D("10000.00") and stmt.closing == D("12650.00")
    assert check_balances(stmt).status == "ok"


def test_ocr_text_tab_separated() -> None:
    text = "Date\tDescription\tDebit\tCredit\tBalance\n05/11/2026\tUPI/DR/430612345679/ZEPTO/x@ybl\t99.00\t\t901.00\n"
    stmt = parse_rows(read_text(text).rows, text_rows=True)
    assert len(stmt.rows) == 1 and stmt.rows[0].amount == D("99.00") and stmt.rows[0].direction == "debit"


def test_paytm_passbook_profile_signed_amounts() -> None:
    data = paytm_csv([
        (date(2026, 10, 3), "Paid to Swiggy", "swiggy@ybl", D("-450.50"), "427512345601"),
        (date(2026, 10, 6), "Received from Rahul Kumar", "rahulk@oksbi", D("2000.00"), "427512345699"),
    ])  # fmt: skip
    stmt = parse_rows(CsvReader().read(data).rows)
    assert stmt.header is not None and (stmt.header.profile, stmt.header.source_kind) == (
        "paytm_passbook",
        "upi_app",
    )
    assert [(r.direction, r.amount, r.ref) for r in stmt.rows] == [
        ("debit", D("450.50"), "427512345601"),
        ("credit", D("2000.00"), "427512345699"),
    ]
    assert check_balances(stmt).status == "not_available"


def test_bhim_profile_skips_failed_attempts() -> None:
    csv_text = (
        "Transaction Date,Paid To / Received From,UPI Ref No,Amount,Type,Status,Remarks\n"
        "07-Oct-26,BLINKIT,427512345621,250.00,DEBIT,SUCCESS,groceries\n"
        "07-Oct-26,BLINKIT,427512345622,250.00,DEBIT,FAILED,groceries\n"
    )
    stmt = parse_rows(CsvReader().read(csv_text.encode()).rows)
    assert stmt.header is not None and stmt.header.profile == "bhim_upi"
    assert len(stmt.rows) == 1 and [s.reason for s in stmt.skipped] == ["failed transaction"]


def test_no_header_detected() -> None:
    assert detect_header([["hello", "world"], ["1", "2"]]) is None
    assert parse_rows([["hello"]]).header is None
