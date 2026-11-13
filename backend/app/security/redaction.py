"""Mask Indian personal identifiers before text leaves the machine. Pure functions, no I/O.

Masks: email, UPI ID, bank account number (only next to an account keyword), payment card number
(13-19 digits, Luhn-valid), Aadhaar (12 digits, first digit 2-9), IFSC, PAN, Indian mobile number.
Order matters: earlier rules replace their match with a placeholder that later rules cannot match.
The bias is toward masking: an Aadhaar-shaped number is masked without its checksum being verified.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass, field


@dataclass(frozen=True)
class RedactionResult:
    text: str
    counts: dict[str, int] = field(default_factory=dict)  # kind -> number of masked items

    @property
    def redacted(self) -> bool:
        return bool(self.counts)


def placeholder(kind: str) -> str:
    return f"[redacted:{kind}]"


def luhn_ok(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = ord(ch) - 48
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


_EMAIL = re.compile(r"(?<![\w.+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
# UPI handle: no dot after "@" (that would be an email domain, already masked above).
_UPI = re.compile(r"(?<![\w.-])[A-Za-z0-9._-]{2,256}@[A-Za-z][A-Za-z0-9]{1,63}(?![\w.@-])")
_ACCOUNT = re.compile(
    r"(?i)\b(?:a/c|acct|account|acc|khata)\.?(?:\s*(?:no\.?|number|num|#))?\s*[:\-]?\s*"
    r"(?P<num>(?<!\d)\d(?:[ -]?\d){8,17}(?!\d))"
)
_CARD = re.compile(r"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)")
_AADHAAR = re.compile(r"(?<!\d)[2-9]\d{3}([ -]?)\d{4}\1\d{4}(?!\d)")
_IFSC = re.compile(r"\b[A-Z]{4}0[A-Z0-9]{6}\b")
_PAN = re.compile(r"\b[A-Z]{3}[ABCFGHJLPT][A-Z]\d{4}[A-Z]\b")
_PHONE = re.compile(r"(?<![\w+])(?:(?:\+|00)91[\s-]?|0)?[6-9]\d{4}[\s-]?\d{5}(?!\d)")


def _digits(s: str) -> str:
    return re.sub(r"\D", "", s)


def redact_text(text: str) -> RedactionResult:
    counts: dict[str, int] = {}

    def bump(kind: str) -> str:
        counts[kind] = counts.get(kind, 0) + 1
        return placeholder(kind)

    def simple(kind: str) -> Callable[[re.Match[str]], str]:
        return lambda _m: bump(kind)

    def account(m: re.Match[str]) -> str:
        start, end = m.span("num")
        offset = m.start()
        whole = m.group(0)
        return whole[: start - offset] + bump("bank_account") + whole[end - offset :]

    def card(m: re.Match[str]) -> str:
        d = _digits(m.group(0))
        if 13 <= len(d) <= 19 and luhn_ok(d):
            return bump("card")
        return m.group(0)

    out = _EMAIL.sub(simple("email"), text)
    out = _UPI.sub(simple("upi"), out)
    out = _ACCOUNT.sub(account, out)
    out = _CARD.sub(card, out)
    out = _AADHAAR.sub(simple("aadhaar"), out)
    out = _IFSC.sub(simple("ifsc"), out)
    out = _PAN.sub(simple("pan"), out)
    out = _PHONE.sub(simple("phone"), out)
    return RedactionResult(out, counts)
