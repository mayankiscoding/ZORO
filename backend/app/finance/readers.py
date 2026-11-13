"""Statement readers: bytes -> rows of cell text. One interface for CSV, Excel, PDF and OCR text.

The backend has no OCR engine. Scanned statements are recognised on the device (Apple Vision) and
the text is sent here; `read_text` splits it into rows. A PDF without a text layer yields no rows
and the import says so.
"""

from __future__ import annotations

import csv
import io
import re
from dataclasses import dataclass, field
from datetime import date, datetime, time
from decimal import Decimal
from typing import Literal, Protocol

from app.finance.formats import AmountError, DateError, parse_amount, parse_date

FileKind = Literal["csv", "xlsx", "pdf", "ocr_text"]
MAX_ROWS = 20000


class StatementReadError(ValueError):
    """The file cannot be read as a statement (wrong type, encrypted, no text layer, ...)."""


@dataclass
class RawTable:
    kind: FileKind
    rows: list[list[str]] = field(default_factory=list)
    text_rows: bool = False  # rows were split from free text (blank cells may be missing)


class StatementReader(Protocol):
    kind: FileKind

    def read(self, data: bytes) -> RawTable: ...


def _cell(value: object) -> str:
    """Spreadsheet cell -> text. Excel stores numbers as binary floats: the shortest repr is the
    value the owner typed, so it is converted to text here and parsed exactly as Decimal later."""
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, time):
        return value.isoformat()
    if isinstance(value, float):
        return str(Decimal(repr(value)))
    return str(value).strip()


class CsvReader:
    kind: FileKind = "csv"

    def read(self, data: bytes) -> RawTable:
        for encoding in ("utf-8-sig", "cp1252", "latin-1"):
            try:
                text = data.decode(encoding)
                break
            except UnicodeDecodeError:
                continue
        if "\x00" in text:
            raise StatementReadError("not a text file")
        sample = text[:8192]
        try:
            dialect: type[csv.Dialect] | csv.Dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")
        except csv.Error:
            dialect = csv.excel
        rows = [[c.strip() for c in row] for row in csv.reader(io.StringIO(text), dialect)]
        return RawTable("csv", rows[:MAX_ROWS])


class XlsxReader:
    kind: FileKind = "xlsx"

    def read(self, data: bytes) -> RawTable:
        from openpyxl import load_workbook

        try:
            book = load_workbook(io.BytesIO(data), read_only=True, data_only=True)
        except Exception as exc:  # openpyxl raises many types for a bad file
            raise StatementReadError("not a readable .xlsx workbook") from exc
        best: list[list[str]] = []
        try:
            for sheet in book.worksheets:
                rows = [[_cell(v) for v in row] for row in sheet.iter_rows(values_only=True)]
                if len(rows) > len(best):
                    best = rows
        finally:
            book.close()
        return RawTable("xlsx", best[:MAX_ROWS])


class PdfReader:
    """Ruled tables via pdfplumber; pages without a ruled table fall back to their text lines."""

    kind: FileKind = "pdf"

    def read(self, data: bytes) -> RawTable:
        import pdfplumber

        rows: list[list[str]] = []
        text_rows = False
        try:
            with pdfplumber.open(io.BytesIO(data)) as pdf:
                for page in pdf.pages:
                    tables = page.extract_tables()
                    if tables:
                        for table in tables:
                            rows.extend([_cell(c).replace("\n", " ") for c in row] for row in table)
                        continue
                    text = page.extract_text() or ""
                    if text.strip():
                        text_rows = True
                        rows.extend(split_text(text))
        except StatementReadError:
            raise
        except Exception as exc:  # pdfminer raises many types for encrypted or broken files
            raise StatementReadError("not a readable PDF (it may be encrypted)") from exc
        if not rows:
            raise StatementReadError(
                "the PDF has no text layer; scan it on your phone so the text is recognised there"
            )
        return RawTable("pdf", rows[:MAX_ROWS], text_rows=text_rows)


def read_text(text: str) -> RawTable:
    """OCR text produced on the device -> rows."""
    return RawTable("ocr_text", split_text(text)[:MAX_ROWS], text_rows=True)


# ---------------------------------------------------------------- free text -> cells

_DELIMITED = re.compile(r"\t|\s*\|\s*|\s{2,}")
_DRCR_TOKEN = re.compile(r"(?i)^(dr|cr)\.?$")


def _is_amount(token: str) -> bool:
    try:
        return parse_amount(token) is not None and any(ch.isdigit() for ch in token)
    except AmountError:
        return False


def _leading_date(tokens: list[str]) -> int:
    """How many leading tokens form a date (0 when none)."""
    for n in (3, 2, 1):
        if len(tokens) >= n:
            try:
                parse_date(" ".join(tokens[:n]))
                return n
            except DateError:
                continue
    return 0


def split_line(line: str) -> list[str]:
    """One text line -> cells. Tab / pipe / wide-space separated text splits on the separators;
    single-spaced text becomes [date, (value date), narration, amounts...]."""
    stripped = line.strip().strip("|").strip()
    if not stripped:
        return []
    for sep in ("\t", "|"):  # explicit separators keep blank cells, so columns stay aligned
        if sep in stripped:
            return [c.strip() for c in stripped.split(sep)]
    if _DELIMITED.search(stripped):
        return [c.strip() for c in _DELIMITED.split(stripped) if c.strip()]
    tokens = stripped.split()
    head = _leading_date(tokens)
    if head == 0:
        return [stripped]
    cells = [" ".join(tokens[:head])]
    rest = tokens[head:]
    second = _leading_date(rest)
    if second:
        cells.append(" ".join(rest[:second]))
        rest = rest[second:]
    tail: list[str] = []
    while rest and len(tail) < 4:
        token = rest[-1]
        if _DRCR_TOKEN.match(token) and len(rest) > 1 and _is_amount(rest[-2]):
            tail.insert(0, f"{rest[-2]} {token}")
            rest = rest[:-2]
        elif _is_amount(token) and ("." in token or "," in token):
            tail.insert(0, token)
            rest = rest[:-1]
        else:
            break
    if rest:
        cells.append(" ".join(rest))
    return cells + tail


def split_text(text: str) -> list[list[str]]:
    return [cells for line in text.splitlines() if (cells := split_line(line))]


READERS: dict[FileKind, StatementReader] = {"csv": CsvReader(), "xlsx": XlsxReader(), "pdf": PdfReader()}


def detect_kind(filename: str, data: bytes) -> FileKind:
    if data.startswith(b"%PDF"):
        return "pdf"
    if data.startswith(b"PK\x03\x04"):
        return "xlsx"
    lower = filename.lower()
    if lower.endswith((".xls",)):
        raise StatementReadError("old .xls workbooks are not supported; save it as .xlsx or .csv")
    if lower.endswith((".csv", ".txt", ".tsv")) or b"\x00" not in data[:4096]:
        return "csv"
    raise StatementReadError("unsupported file type; send CSV, XLSX or PDF")


def read_statement(filename: str, data: bytes) -> RawTable:
    if not data:
        raise StatementReadError("the file is empty")
    return READERS[detect_kind(filename, data)].read(data)
