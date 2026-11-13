"""Recipient resolution. A message is prepared only for a recipient resolved to exactly one contact
(and one address): several matches come back as a clarification, never as a guess."""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Literal

from pydantic import BaseModel

from app.communications.google.gmail import valid_address

Channel = Literal["whatsapp", "sms", "imessage", "email"]
PHONE_CHANNELS = ("whatsapp", "sms", "imessage")


class Candidate(BaseModel):
    """One (contact, address) pair the owner could mean."""

    ref: str | None = None  # the device's contact reference
    name: str
    address: str  # phone: international digits; email: lower-case address
    kind: Literal["phone", "email"]
    label: str  # what the owner sees: "+91 98765 43210" or the address


def normalise_phone(raw: str) -> str | None:
    """International digits for wa.me and the Messages composer. A bare Indian mobile (10 digits starting
    6-9, or 0 + 10) is read as +91; anything else must already carry its country code."""
    digits = re.sub(r"\D", "", raw)
    if digits.startswith("00"):
        digits = digits[2:]
    elif len(digits) == 11 and digits.startswith("0"):
        digits = digits[1:]
    if len(digits) == 10 and digits[0] in "6789":
        digits = "91" + digits
    return digits if re.fullmatch(r"[1-9]\d{7,14}", digits) else None


def display_phone(digits: str) -> str:
    if digits.startswith("91") and len(digits) == 12:
        return f"+91 {digits[2:7]} {digits[7:]}"
    return f"+{digits}"


def _fold(text: str) -> str:
    return unicodedata.normalize("NFC", text).casefold().strip()


def name_matches(name: str, query: str) -> bool:
    """Every word of the query is the start of a word of the name (so "rahul" finds "Rahul Verma")."""
    words = _fold(name).split()
    wanted = _fold(query).split()
    return bool(wanted) and all(any(w.startswith(q) for w in words) for q in wanted)


def candidates_from_contacts(contacts: Sequence[Mapping[str, Any]], channel: Channel) -> list[Candidate]:
    """Expand device contacts (`device.contacts.find` matches) into addressable candidates."""
    out: list[Candidate] = []
    for contact in contacts:
        name = str(contact.get("name", "")).strip()
        ref = contact.get("contact_ref")
        if not name:
            continue
        if channel == "email":
            for email in contact.get("emails") or []:
                address = str(email).strip().lower()
                if valid_address(address):
                    out.append(Candidate(ref=ref, name=name, address=address, kind="email", label=address))
        else:
            seen: set[str] = set()
            for phone in contact.get("phones") or []:
                digits = normalise_phone(str(phone))
                if digits and digits not in seen:
                    seen.add(digits)
                    out.append(
                        Candidate(
                            ref=ref, name=name, address=digits, kind="phone", label=display_phone(digits)
                        )
                    )
    return out


def explicit_candidate(value: str, channel: Channel) -> Candidate | None:
    """An address the owner gave directly ("email hr@example.com", "+91 98765 43210")."""
    value = value.strip()
    if channel == "email":
        address = value.lower()
        return (
            Candidate(name=address, address=address, kind="email", label=address)
            if valid_address(address)
            else None
        )
    digits = normalise_phone(value)
    if digits is None:
        return None
    return Candidate(name=display_phone(digits), address=digits, kind="phone", label=display_phone(digits))


@dataclass(frozen=True)
class Resolution:
    outcome: Literal["one", "none", "ambiguous"]
    candidates: list[Candidate]

    @property
    def chosen(self) -> Candidate | None:
        return self.candidates[0] if self.outcome == "one" else None


def resolve(candidates: Sequence[Candidate]) -> Resolution:
    """De-duplicate identical addresses of the same contact, then require exactly one."""
    unique: dict[tuple[str | None, str, str], Candidate] = {}
    for c in candidates:
        unique.setdefault((c.ref, c.name, c.address), c)
    items = list(unique.values())
    if not items:
        return Resolution("none", [])
    if len(items) == 1:
        return Resolution("one", items)
    return Resolution("ambiguous", items)
