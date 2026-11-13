"""Header detection, column aliases and row parsing for statement tables.

Bank and UPI app layouts are *column aliases* (`PROFILES`), never data. A header row is the row
whose cells map to the most known columns (it must have a date, an amount and a description).
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal
from itertools import pairwise
from typing import Literal

from app.finance.formats import AmountError, DateError, Direction, ParsedAmount, parse_amount, parse_date

SourceKind = Literal["bank", "upi_app"]
_KEY = re.compile(r"[^a-z0-9]+")
_BAD_STATUS = {"failed", "failure", "pending", "declined", "cancelled", "rejected", "expired"}


def akey(text: str) -> str:
    return _KEY.sub("", text.lower())


@dataclass(frozen=True)
class Profile:
    name: str
    source_kind: SourceKind
    aliases: Mapping[str, tuple[str, ...]]  # canonical column -> header aliases (akey form)


GENERIC: dict[str, tuple[str, ...]] = {
    "date": ("date", "txndate", "transactiondate", "trandate", "postingdate", "txnpostingdate", "dateoftransaction"),
    "value_date": ("valuedate", "valuedt"),
    "narration": ("narration", "description", "particulars", "transactionremarks", "remarks", "details",
                  "transactiondetails", "transactiondescription"),
    "ref": ("chqrefno", "refno", "refnochequeno", "chequeno", "chequenumber", "chqno", "referenceno", "orderid"),
    "upi_ref": ("upirefno", "upireferenceno", "rrn", "utr", "utrno", "upitransactionid", "transactionid"),
    "debit": ("debit", "withdrawal", "withdrawals", "withdrawalamt", "withdrawalamount", "withdrawalamountinr",
              "debitamount", "dr", "debitinr"),
    "credit": ("credit", "deposit", "deposits", "depositamt", "depositamount", "depositamountinr",
               "creditamount", "cr", "creditinr"),
    "amount": ("amount", "amountinr", "amountrs", "txnamount", "transactionamount"),
    "drcr": ("drcr", "crdr", "type", "debitcredit", "transactiontype"),
    "balance": ("balance", "closingbalance", "bal", "runningbalance", "balanceinr", "availablebalance"),
    "counterparty": ("paidtoreceivedfrom", "othertransactiondetailsupiidoracno", "counterparty", "payee", "name"),
    "status": ("status", "transactionstatus"),
}  # fmt: skip

PROFILES: tuple[Profile, ...] = (
    Profile("hdfc_bank", "bank", {"date": ("date",), "narration": ("narration",), "ref": ("chqrefno",),
            "value_date": ("valuedt",), "debit": ("withdrawalamt",), "credit": ("depositamt",),
            "balance": ("closingbalance",)}),
    Profile("sbi", "bank", {"date": ("txndate",), "value_date": ("valuedate",), "narration": ("description",),
            "ref": ("refnochequeno",), "debit": ("debit",), "credit": ("credit",), "balance": ("balance",)}),
    Profile("icici_bank", "bank", {"date": ("transactiondate",), "value_date": ("valuedate",),
            "narration": ("transactionremarks",), "ref": ("chequenumber",), "debit": ("withdrawalamountinr",),
            "credit": ("depositamountinr",), "balance": ("balanceinr",)}),
    Profile("axis_bank", "bank", {"date": ("trandate",), "ref": ("chqno",), "narration": ("particulars",),
            "debit": ("dr",), "credit": ("cr",), "balance": ("bal",)}),
    Profile("kotak_bank", "bank", {"date": ("transactiondate",), "narration": ("description",),
            "ref": ("chqrefno",), "amount": ("amount",), "drcr": ("drcr",), "balance": ("balance",)}),
    Profile("paytm_passbook", "upi_app", {"date": ("date",), "narration": ("transactiondetails",),
            "counterparty": ("othertransactiondetailsupiidoracno",), "amount": ("amount",),
            "upi_ref": ("upirefno",), "ref": ("orderid",)}),
    Profile("bhim_upi", "upi_app", {"date": ("transactiondate",), "counterparty": ("paidtoreceivedfrom",),
            "upi_ref": ("upirefno", "transactionid"), "amount": ("amount",), "drcr": ("type",),
            "status": ("status",), "narration": ("remarks",)}),
    Profile("phonepe", "upi_app", {"date": ("date",), "narration": ("transactiondetails",), "drcr": ("type",),
            "amount": ("amount",), "upi_ref": ("utrno",)}),
)  # fmt: skip

_ALL_ALIASES = {a for aliases in GENERIC.values() for a in aliases}


@dataclass(frozen=True)
class Header:
    index: int
    profile: str
    source_kind: SourceKind
    columns: Mapping[str, int]  # canonical -> cell index


@dataclass(frozen=True)
class ParsedRow:
    line: int  # 1-based row number in the file
    txn_date: date
    value_date: date | None
    narration: str
    direction: Direction
    amount: Decimal  # > 0, rupees
    balance: Decimal | None = None
    ref: str | None = None  # UPI reference / RRN / UTR from its own column
    counterparty: str | None = None


@dataclass(frozen=True)
class RowError:
    line: int
    reason: str


@dataclass
class ParsedStatement:
    header: Header | None
    rows: list[ParsedRow] = field(default_factory=list)
    errors: list[RowError] = field(default_factory=list)
    skipped: list[RowError] = field(default_factory=list)  # not errors: failed UPI attempts, summaries
    opening: Decimal | None = None
    closing: Decimal | None = None


def _greedy_cells(text: str) -> list[str]:
    """Split a single-spaced header line by the longest known aliases ("Value Dt" stays one cell)."""
    words, cells, i = text.split(), [], 0
    while i < len(words):
        for n in (5, 4, 3, 2, 1):
            if i + n <= len(words) and (n == 1 or akey("".join(words[i : i + n])) in _ALL_ALIASES):
                cells.append(" ".join(words[i : i + n]))
                i += n
                break
    return cells


def _map(cells: list[str], profile: Profile) -> tuple[dict[str, int], int]:
    columns: dict[str, int] = {}
    specific = 0
    for idx, cell in enumerate(cells):
        key = akey(cell)
        if not key:
            continue
        for canonical, aliases in profile.aliases.items():
            if key in aliases and canonical not in columns:
                columns[canonical], specific = idx, specific + 1
                break
        else:
            for canonical, aliases in GENERIC.items():
                if key in aliases and canonical not in columns:
                    columns[canonical] = idx
                    break
    return columns, specific


def detect_header(rows: list[list[str]], *, scan: int = 60) -> tuple[Header, list[str]] | None:
    best: tuple[tuple[int, int, int], Header, list[str]] | None = None
    for index, raw in enumerate(rows[:scan]):
        cells = _greedy_cells(raw[0]) if len(raw) == 1 else raw
        for profile in PROFILES:
            columns, specific = _map(cells, profile)
            has_amount = bool({"amount", "debit", "credit"} & columns.keys())
            if (
                "date" not in columns
                or not has_amount
                or not ({"narration", "counterparty"} & columns.keys())
            ):
                continue
            exact = int(specific == len(profile.aliases))
            score = (exact, len(columns), specific)
            if best is None or score > best[0]:
                header = Header(index, profile.name, profile.source_kind, columns)
                best = (score, header, cells)
    if best is None:
        return None
    _, header, cells = best
    if best[0][0] == 0:  # no profile matched completely: report a generic layout
        kind: SourceKind = (
            "upi_app" if "upi_ref" in header.columns and "balance" not in header.columns else "bank"
        )
        header = Header(header.index, "generic", kind, header.columns)
    return header, cells


_BAL_RE = re.compile(
    r"(?i)\b(opening|closing)\s*bal(ance)?\b[^0-9(₹+-]*([+-]?\(?₹?\s*[\d,]+(\.\d{1,2})?\)?(\s*(dr|cr))?)"
)


def _summary_balances(rows: list[list[str]]) -> tuple[Decimal | None, Decimal | None]:
    found: dict[str, Decimal] = {}
    for raw in rows:
        line = "  ".join(c for c in raw if c)
        for m in _BAL_RE.finditer(line):
            try:
                amount = parse_amount(m.group(3))
            except AmountError:
                continue
            if amount is not None:
                found.setdefault(m.group(1).lower(), _balance_value(amount))
    return found.get("opening"), found.get("closing")


def _balance_value(amount: ParsedAmount) -> Decimal:
    negative = amount.sign < 0 or amount.direction == "debit"  # an overdrawn balance reads "Dr"
    return -amount.value if negative else amount.value


def _get(cells: list[str], columns: Mapping[str, int], name: str) -> str:
    idx = columns.get(name)
    return cells[idx].strip() if idx is not None and idx < len(cells) else ""


def _amounts(cells: list[str], columns: Mapping[str, int]) -> tuple[Decimal, Direction, Decimal | None]:
    """(amount > 0, direction, balance) from one row. Raises ValueError with a reason."""
    debit = parse_amount(_get(cells, columns, "debit")) if "debit" in columns else None
    credit = parse_amount(_get(cells, columns, "credit")) if "credit" in columns else None
    bal_cell = parse_amount(_get(cells, columns, "balance")) if "balance" in columns else None
    balance = _balance_value(bal_cell) if bal_cell is not None else None
    if debit is not None and debit.value and credit is not None and credit.value:
        raise ValueError("both debit and credit are filled")
    if debit is not None and debit.value:
        return debit.value, "debit", balance
    if credit is not None and credit.value:
        return credit.value, "credit", balance
    amount = parse_amount(_get(cells, columns, "amount")) if "amount" in columns else None
    if amount is None or not amount.value:
        raise ValueError("no amount")
    marker = akey(_get(cells, columns, "drcr"))
    if marker in ("dr", "debit", "d", "paid", "sent", "withdrawal"):
        return amount.value, "debit", balance
    if marker in ("cr", "credit", "c", "received", "deposit", "refund"):
        return amount.value, "credit", balance
    if amount.direction is not None:
        return amount.value, amount.direction, balance
    if amount.sign != 0:
        return amount.value, "debit" if amount.sign < 0 else "credit", balance
    raise ValueError("cannot tell debit from credit")


def _realign(
    cells: list[str], header: Header, prev_balance: Decimal | None
) -> tuple[list[str], dict[str, int]]:
    """Rows split from text lose blank cells. Rebuild [date, (value date), narration, amounts...]."""
    columns = dict(header.columns)
    money_cols = [c for c in ("debit", "credit", "amount", "balance") if c in columns]
    tail: list[str] = []
    rest = list(cells)
    while len(rest) > 1 and len(tail) < len(money_cols):
        try:
            if parse_amount(rest[-1]) is None:
                break
        except AmountError:
            break
        tail.insert(0, rest.pop())
    lead = 2 if "value_date" in columns and len(rest) > 2 else 1
    fixed = [*rest[:lead], " ".join(rest[lead:])]
    new = {"date": 0, "narration": lead}
    if lead == 2:
        new["value_date"] = 1
    if len(tail) == len(money_cols):
        for i, col in enumerate(money_cols):
            new[col] = len(fixed) + i
        return fixed + tail, new
    if len(tail) == 2 and "balance" in columns and {"debit", "credit"} <= columns.keys():
        amount = parse_amount(tail[0])
        balance = parse_amount(tail[1])
        if amount is not None and balance is not None and prev_balance is not None:
            bal = _balance_value(balance)
            if prev_balance - amount.value == bal:
                new.update(debit=len(fixed), balance=len(fixed) + 1)
                return fixed + tail, new
            if prev_balance + amount.value == bal:
                new.update(credit=len(fixed), balance=len(fixed) + 1)
                return fixed + tail, new
        if amount is not None and amount.direction is not None:
            new.update({amount.direction: len(fixed), "balance": len(fixed) + 1})
            return fixed + tail, new
    raise ValueError("cannot place the amounts in this row")


def parse_rows(rows: list[list[str]], *, text_rows: bool = False) -> ParsedStatement:
    found = detect_header(rows)
    if found is None:
        return ParsedStatement(None, errors=[RowError(0, "no statement header found")])
    header, _cells = found
    stmt = ParsedStatement(header)
    stmt.opening, stmt.closing = _summary_balances(rows[: header.index] + rows[header.index + 1 :])
    prev_balance = stmt.opening
    width = len(_cells)
    header_keys = [akey(c) for c in _cells]
    for offset, cells in enumerate(rows[header.index + 1 :], start=header.index + 2):
        if not any(c.strip() for c in cells):
            continue
        columns: Mapping[str, int] = header.columns
        if [akey(c) for c in cells] == header_keys:
            continue  # the header repeated on a new page
        joined = " ".join(cells).lower()
        try:
            txn_date = parse_date(_get(cells, columns, "date"))
        except DateError:
            if "opening balance" in joined or "closing balance" in joined or "total" in joined:
                stmt.skipped.append(RowError(offset, "summary row"))
            elif any(c.strip() for c in cells[1:]):
                stmt.errors.append(RowError(offset, "invalid date"))
            continue
        try:
            if text_rows and len(cells) != width:
                cells, columns = _realign(cells, header, prev_balance)
            status = akey(_get(cells, columns, "status"))
            if status in _BAD_STATUS:
                stmt.skipped.append(RowError(offset, f"{status} transaction"))
                continue
            amount, direction, balance = _amounts(cells, columns)
        except (ValueError, AmountError) as exc:
            stmt.errors.append(RowError(offset, str(exc) or "invalid amount"))
            continue
        try:
            value_date = parse_date(_get(cells, columns, "value_date")) if "value_date" in columns else None
        except DateError:
            value_date = None
        narration = _get(cells, columns, "narration") or _get(cells, columns, "counterparty")
        stmt.rows.append(
            ParsedRow(
                line=offset,
                txn_date=txn_date,
                value_date=value_date,
                narration=re.sub(r"\s+", " ", narration),
                direction=direction,
                amount=amount,
                balance=balance,
                ref=_get(cells, columns, "upi_ref") or None,
                counterparty=_get(cells, columns, "counterparty") or None,
            )
        )
        if balance is not None:
            prev_balance = balance
    return stmt


@dataclass(frozen=True)
class BalanceCheck:
    status: Literal["ok", "mismatch", "not_available"]
    detail: str = ""


def check_balances(stmt: ParsedStatement) -> BalanceCheck:
    """Running balance (either row order) and opening + credits - debits = closing, when present."""
    problems: list[str] = []
    checked = False
    rows = [(r, r.balance) for r in stmt.rows if r.balance is not None]
    if len(rows) >= 2 and len(rows) == len(stmt.rows):
        checked = True

        def delta(r: ParsedRow) -> Decimal:
            return r.amount if r.direction == "credit" else -r.amount

        pairs = list(pairwise(rows))
        forward = [b.line for (_a, ab), (b, bb) in pairs if ab + delta(b) != bb]
        backward = [a.line for (a, ab), (_b, bb) in pairs if bb + delta(a) != ab]
        if forward and backward:
            problems.append(f"running balance breaks at row {min(forward)}")
    if stmt.opening is not None and stmt.closing is not None:
        checked = True
        net = sum((r.amount if r.direction == "credit" else -r.amount for r in stmt.rows), Decimal(0))
        if stmt.opening + net != stmt.closing:
            problems.append(f"opening {stmt.opening} + net {net} != closing {stmt.closing}")
    if not checked:
        return BalanceCheck("not_available")
    return BalanceCheck("mismatch", "; ".join(problems)) if problems else BalanceCheck("ok")
