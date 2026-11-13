"""Synthetic statements for tests only. Every name, reference and amount here is made up."""

from __future__ import annotations

import csv
import io
from collections.abc import Sequence
from datetime import date, datetime
from decimal import Decimal

from app.core.money import group_indian

Row = tuple[date, str, str | None, Decimal | None, Decimal | None]  # date, narration, ref, debit, credit


def inr(value: Decimal) -> str:
    whole, _, frac = f"{abs(value):.2f}".partition(".")
    return ("-" if value < 0 else "") + group_indian(whole) + "." + frac


def with_balances(rows: Sequence[Row], opening: Decimal) -> list[tuple[Row, Decimal]]:
    out, bal = [], opening
    for row in rows:
        bal = bal - (row[3] or 0) + (row[4] or 0)
        out.append((row, bal))
    return out


def hdfc_csv(rows: Sequence[Row], opening: Decimal, *, extra: Sequence[list[str]] = ()) -> bytes:
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["HDFC BANK Ltd. (synthetic test statement)"])
    w.writerow(["Opening Balance", inr(opening)])
    w.writerow(
        [
            "Date",
            "Narration",
            "Chq./Ref.No.",
            "Value Dt",
            "Withdrawal Amt.",
            "Deposit Amt.",
            "Closing Balance",
        ]
    )
    final = opening
    for (day, narration, ref, debit, credit), bal in with_balances(rows, opening):
        d = day.strftime("%d/%m/%y")
        w.writerow(
            [d, narration, ref or "", d, inr(debit) if debit else "", inr(credit) if credit else "", inr(bal)]
        )
        final = bal
    for row in extra:
        w.writerow(row)
    w.writerow(["Closing Balance", inr(final)])
    return buf.getvalue().encode()


def generic_csv(rows: Sequence[Row], opening: Decimal = Decimal("100000.00")) -> bytes:
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["Date", "Description", "Debit", "Credit", "Balance"])
    for (day, narration, _ref, debit, credit), bal in with_balances(rows, opening):
        w.writerow(
            [day.isoformat(), narration, inr(debit) if debit else "", inr(credit) if credit else "", inr(bal)]
        )
    return buf.getvalue().encode()


def paytm_csv(rows: Sequence[tuple[date, str, str, Decimal, str]]) -> bytes:
    """(date, details, vpa, signed amount, upi ref)."""
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["Date", "Time", "Transaction Details", "Other Transaction Details (UPI ID or A/c No)",
                "Your Account", "Amount", "UPI Ref No.", "Order ID", "Remarks", "Tags", "Comment"])  # fmt: skip
    for day, details, vpa, amount, ref in rows:
        sign = "-" if amount < 0 else "+"
        w.writerow([day.strftime("%d/%m/%Y"), "13:05:22", details, vpa, "Test Bank - 0000",
                    f"{sign}{inr(abs(amount))}", ref, "", "", "", ""])  # fmt: skip
    return buf.getvalue().encode()


def sbi_xlsx(rows: Sequence[Sequence[object]]) -> bytes:
    from openpyxl import Workbook

    book = Workbook()
    sheet = book.active
    sheet.append(["State Bank of India - synthetic account statement"])
    sheet.append([])
    sheet.append(
        ["Txn Date", "Value Date", "Description", "Ref No./Cheque No.", "Debit", "Credit", "Balance"]
    )
    for row in rows:
        sheet.append(list(row))
    buf = io.BytesIO()
    book.save(buf)
    return buf.getvalue()


def _pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def ruled_pdf(rows: Sequence[Sequence[str]], widths: Sequence[int], *, title: str = "Statement") -> bytes:
    """A one-page PDF with a ruled table (lines drawn around every cell), Helvetica text."""
    left, top, height = 30, 760, 18
    xs = [left]
    for w in widths:
        xs.append(xs[-1] + w)
    ys = [top - i * height for i in range(len(rows) + 1)]
    ops = [f"BT /F1 12 Tf {left} {top + 20} Td ({_pdf_escape(title)}) Tj ET", "0.5 w"]
    for y in ys:
        ops.append(f"{xs[0]} {y} m {xs[-1]} {y} l S")
    for x in xs:
        ops.append(f"{x} {ys[0]} m {x} {ys[-1]} l S")
    for r, row in enumerate(rows):
        for c, text in enumerate(row):
            if text:
                ops.append(f"BT /F1 7 Tf {xs[c] + 2} {ys[r] - 12} Td ({_pdf_escape(text)}) Tj ET")
    stream = "\n".join(ops).encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 842] /Resources << /Font << /F1 4 0 R >> >> "
        b"/Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


def xl_date(day: date) -> datetime:
    return datetime(day.year, day.month, day.day)
