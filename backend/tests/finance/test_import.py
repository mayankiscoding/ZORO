from __future__ import annotations

from datetime import date
from decimal import Decimal

from sqlalchemy import func, inspect, select

from app.finance.models import FinanceAccount, FinanceImport, FinanceTransaction
from app.plugins import PluginRegistry
from tests.finance.samples import hdfc_csv, paytm_csv

D = Decimal
BANK = [
    (date(2026, 10, 1), "NEFT CR-HDFC0000001-ACME CORP-SALARY OCT", None, None, D("100000.00")),
    (
        date(2026, 10, 3),
        "UPI-SWIGGY-SWIGGY@YBL-YESB0YBLUPI-427512345601-PAYMENT FROM PHONE",
        None,
        D("450.50"),
        None,
    ),
    (date(2026, 10, 4), "UPI/427512345603/Payment/9876543210@ybl/SBI", None, D("1200.00"), None),
    (date(2026, 10, 5), "POS 416021XXXXXX1234 DMART BANGALORE", None, D("2345.75"), None),
]
APP = [
    (date(2026, 10, 3), "Paid to Swiggy", "swiggy@ybl", D("-450.50"), "427512345601"),
    (date(2026, 10, 4), "Paid to Rahul Kumar", "9876543210@ybl", D("-1200.00"), "427512345603"),
    (date(2026, 10, 7), "Paid to Zepto", "zepto@ybl", D("-199.00"), "427512345640"),
]


async def _rows(registry: PluginRegistry) -> list[FinanceTransaction]:
    async with registry.service("session_factory")() as s:
        return list((await s.scalars(select(FinanceTransaction).order_by(FinanceTransaction.txn_date))).all())


async def test_import_is_idempotent_by_file_hash(registry: PluginRegistry) -> None:
    imports = registry.service("finance_imports")
    data = hdfc_csv(BANK, D("50000.00"))
    first = await imports.import_file("hdfc-oct.csv", data)
    assert (first.status, first.profile, first.rows_imported, first.balance_check) == (
        "completed",
        "hdfc_bank",
        4,
        "ok",
    )
    assert first.account_name == "HDFC Bank" and not first.already_imported
    again = await imports.import_file("renamed.csv", data)
    assert again.already_imported and again.id == first.id
    assert len(await _rows(registry)) == 4
    async with registry.service("session_factory")() as s:
        assert await s.scalar(select(func.count()).select_from(FinanceImport)) == 1


async def test_paise_are_integers_and_no_float_anywhere(registry: PluginRegistry) -> None:
    await registry.service("finance_imports").import_file("hdfc.csv", hdfc_csv(BANK, D("50000.00")))
    rows = await _rows(registry)
    assert [r.amount_paise for r in rows] == [10000000, 45050, 120000, 234575]
    for row in rows:
        for attr in [c.key for c in inspect(FinanceTransaction).column_attrs]:
            assert not isinstance(getattr(row, attr), float), attr
        assert isinstance(row.amount_paise, int) and isinstance(row.balance_paise, int)
    assert rows[1].balance_paise == 14954950


async def test_within_file_duplicate_by_upi_ref(registry: PluginRegistry) -> None:
    data = paytm_csv([APP[0], APP[0], APP[2]])
    result = await registry.service("finance_imports").import_file("paytm.csv", data)
    assert (result.rows_imported, result.rows_duplicate) == (2, 1)
    dup = [r for r in await _rows(registry) if r.duplicate_of]
    assert len(dup) == 1 and dup[0].duplicate_reason == "same_file"


async def test_overlapping_bank_statements_are_not_counted_twice(registry: PluginRegistry) -> None:
    imports = registry.service("finance_imports")
    await imports.import_file("oct-a.csv", hdfc_csv(BANK[:3], D("50000.00")))
    second = await imports.import_file("oct-b.csv", hdfc_csv(BANK, D("50000.00")))
    assert (second.rows_imported, second.rows_duplicate) == (1, 3)
    live = [r for r in await _rows(registry) if r.duplicate_of is None]
    assert len(live) == 4


async def test_upi_app_export_reconciles_with_bank(registry: PluginRegistry) -> None:
    imports = registry.service("finance_imports")
    await imports.import_file("hdfc.csv", hdfc_csv(BANK, D("50000.00")))
    app = await imports.import_file("paytm.csv", paytm_csv(APP))
    assert (app.source_kind, app.rows_reconciled, app.rows_imported, app.rows_duplicate) == (
        "upi_app",
        2,
        1,
        0,
    )
    rows = await _rows(registry)
    reconciled = [r for r in rows if r.duplicate_reason == "reconciled_upi"]
    assert {r.upi_ref for r in reconciled} == {"427512345601", "427512345603"}
    assert all(r.source_kind == "upi_app" for r in reconciled)
    # the bank's anonymous payee takes the app's name
    bank_payee = next(r for r in rows if r.upi_ref == "427512345603" and r.source_kind == "bank")
    assert bank_payee.counterparty == "Rahul Kumar"
    live = [r for r in rows if r.duplicate_of is None]
    assert sum(r.amount_paise for r in live if r.direction == "debit") == 45050 + 120000 + 234575 + 19900


async def test_reconciliation_works_in_either_order(registry: PluginRegistry) -> None:
    imports = registry.service("finance_imports")
    await imports.import_file("paytm.csv", paytm_csv(APP))
    bank = await imports.import_file("hdfc.csv", hdfc_csv(BANK, D("50000.00")))
    assert bank.rows_reconciled == 2 and bank.rows_imported == 4
    rows = await _rows(registry)
    app_rows = [
        r for r in rows if r.source_kind == "upi_app" and r.upi_ref in {"427512345601", "427512345603"}
    ]
    assert all(r.duplicate_of is not None for r in app_rows)
    assert len([r for r in rows if r.duplicate_of is None]) == 5


async def test_import_never_touches_anything_but_finance_tables(registry: PluginRegistry) -> None:
    await registry.service("finance_imports").import_file("hdfc.csv", hdfc_csv(BANK, D("50000.00")))
    async with registry.service("session_factory")() as s:
        accounts = (await s.scalars(select(FinanceAccount))).all()
    assert [(a.name, a.kind) for a in accounts] == [("HDFC Bank", "bank")]


async def test_unreadable_file_fails_and_can_be_retried(registry: PluginRegistry) -> None:
    imports = registry.service("finance_imports")
    result = await imports.import_file("notes.csv", b"just some words\nwithout a header\n")
    assert result.status == "failed" and "header" in result.message
    again = await imports.import_file("notes.csv", b"just some words\nwithout a header\n")
    assert again.status == "failed" and not again.already_imported


async def test_ocr_text_import(registry: PluginRegistry) -> None:
    from tests.finance.test_parsers import OCR_TEXT

    imports = registry.service("finance_imports")
    result = await imports.import_ocr_text(OCR_TEXT, "scan.txt", account_name="Kotak savings")
    assert (result.file_kind, result.rows_imported, result.balance_check) == ("ocr_text", 3, "ok")
    assert (await imports.import_ocr_text(OCR_TEXT, "scan.txt")).already_imported
