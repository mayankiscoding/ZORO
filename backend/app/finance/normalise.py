"""Narration -> merchant, channel, VPA and UPI reference.

Covers the common Indian grammars:
- UPI: ``UPI/DR/412345678901/SWIGGY/YESB/swiggy@ybl/Payment`` (SBI),
  ``UPI-SWIGGY-SWIGGY@YBL-YESB0YBLUPI-412345678901-PAYMENT`` (HDFC),
  ``UPI/412345678901/Payment/swiggy@ybl/YES BANK`` (ICICI), ``UPI/P2M/412345678901/SWIGGY/...`` (Axis)
- cards: ``POS 416021XXXXXX1234 SWIGGY BANGALORE``, ``ECOM PUR/AMAZON PAY/...``
- ``NEFT/N123456789012/ACME CORP/HDFC0001234``, ``NEFT CR-HDFC0000001-ACME CORP-...``
- ``IMPS/P2A/412345678901/RAHUL K/...``, ``MMT/IMPS/412345678901/...``
- ATM (``ATM WDL``, ``ATW-``, ``NWD-``) and cash deposits.
Phone-number VPAs are masked: only the last four digits are kept.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal

Channel = Literal["upi", "card", "neft", "imps", "atm", "cash", "other"]
CHANNELS: tuple[str, ...] = ("upi", "card", "neft", "imps", "atm", "cash", "other")

_VPA = re.compile(r"\b([a-z0-9][a-z0-9._]{1,255})@([a-z][a-z0-9]{1,63})\b", re.I)
_IFSC = re.compile(r"^[A-Z]{4}0[A-Z0-9]{6}$")
_REF12 = re.compile(r"(?<!\d)(\d{12})(?!\d)")
_NEFT_REF = re.compile(r"\b([A-Z]{1,4}\d{9,18}|N\d{6,18})\b")
_CARD_NO = re.compile(r"\b\d{4,6}[X*]{4,8}\d{0,4}\b|\bX{2,}\d{4}\b", re.I)
_SPLIT = re.compile(r"[/\-|:]+")
_NON_WORD = re.compile(r"[^a-z0-9 ]+")
_SPACES = re.compile(r"\s+")

_UPI_NOISE = {
    "upi", "dr", "cr", "p2m", "p2a", "payment", "pay", "paid", "to", "from", "by", "transfer", "upiintent",
    "collect", "request", "sent", "received", "using", "paytm", "phonepe", "gpay", "bhim", "ybl", "ibl",
    "axl", "okaxis", "oksbi", "okhdfcbank", "okicici", "na", "null", "upi payment", "payment from phone",
    "pay to", "mmt", "imps", "neft", "rtgs", "inb", "txn", "ref", "upiar", "upiab", "note", "remarks",
}  # fmt: skip
_BANK_WORDS = {
    "yes bank", "yesb", "hdfc", "hdfc bank", "icici", "icici bank", "sbi", "sbin", "state bank of india",
    "axis", "axis bank", "kotak", "kotak mahindra bank", "kkbk", "utib", "icic", "hdfc0000001", "pytm",
    "paytm payments bank", "airtel payments bank", "idfc first bank", "bank of baroda", "punjab national bank",
    "canara bank", "union bank of india", "indusind bank", "federal bank", "rbl bank", "au small finance bank",
}  # fmt: skip
_CITY_WORDS = {
    "bangalore", "bengaluru", "mumbai", "delhi", "new delhi", "gurgaon", "gurugram", "noida", "pune",
    "hyderabad", "chennai", "kolkata", "in", "ind", "india", "blr", "mum", "del",
}  # fmt: skip


@dataclass(frozen=True)
class Normalised:
    merchant: str  # display name ("Swiggy", "ATM withdrawal", "UPI payee ••3210")
    merchant_key: str  # lower-case grouping key ("swiggy")
    channel: Channel
    vpa: str | None = None
    upi_ref: str | None = None


def merchant_key(name: str) -> str:
    return _SPACES.sub(" ", _NON_WORD.sub(" ", name.lower())).strip()


def _display(name: str, aliases: Mapping[str, str]) -> str:
    key = merchant_key(name)
    if key in aliases:
        return aliases[key]
    for alias, canonical in aliases.items():
        if key.startswith(alias + " "):
            return canonical
    return " ".join(word.capitalize() if word.isalpha() else word for word in name.split()) or name


def _is_noise(token: str) -> bool:
    low = merchant_key(token)
    if not low or low in _UPI_NOISE or low in _BANK_WORDS or low in _CITY_WORDS:
        return True
    if _IFSC.match(token.strip().upper()) or "@" in token:
        return True
    return not any(ch.isalpha() for ch in low) or len(low) < 2


def _vpa_name(vpa: str) -> str | None:
    """A readable name from a VPA's handle: "swiggy.instamart@icici" -> "swiggy instamart"."""
    local = vpa.split("@", 1)[0].lower()
    if re.fullmatch(r"\d{10}", local) or re.fullmatch(r"\d+", local):
        return None
    words = [w for w in re.split(r"[.\-_]+", re.sub(r"\d+$", "", local)) if w]
    return " ".join(words) or None


def mask_vpa(vpa: str) -> str:
    """Phone-number VPAs keep only the last four digits."""
    local, _, handle = vpa.partition("@")
    if re.fullmatch(r"\d{10,12}", local):
        return f"••{local[-4:]}@{handle}"
    return vpa.lower()


def _payee_from_vpa(vpa: str | None) -> str:
    if vpa is None:
        return "UPI payee"
    local = vpa.split("@", 1)[0]
    return f"UPI payee ••{local[-4:]}" if local.isdigit() else "UPI payee"


def _clean_tokens(parts: list[str]) -> list[str]:
    return [p.strip() for p in parts if p.strip() and not _is_noise(p) and not _REF12.fullmatch(p.strip())]


def _result(
    name: str | None, channel: Channel, aliases: Mapping[str, str], **extra: str | None
) -> Normalised:
    display = _display(name, aliases) if name else "Unknown"
    return Normalised(display, merchant_key(display), channel, extra.get("vpa"), extra.get("upi_ref"))


def normalise(narration: str, aliases: Mapping[str, str] | None = None) -> Normalised:
    """Parse a bank narration. `aliases` maps merchant keys to canonical names (from config)."""
    aliases = aliases or {}
    text = _SPACES.sub(" ", narration.strip())
    upper = text.upper()
    vpa_match = _VPA.search(text)
    vpa = mask_vpa(vpa_match.group(0)) if vpa_match else None
    ref_match = _REF12.search(text)
    ref = ref_match.group(1) if ref_match else None

    if re.search(r"\bUPI\b|^UPI|/UPI/|UPI[-/]", upper):
        body = re.sub(r"(?i)^(to transfer|by transfer|trf to|trf from)[- ]*", "", text)
        tokens = _clean_tokens(_SPLIT.split(body))
        name = tokens[0] if tokens else None
        if name is None and vpa_match is not None:
            name = _vpa_name(vpa_match.group(0))
        if name is None:
            payee = _payee_from_vpa(vpa_match.group(0) if vpa_match else None)
            return Normalised(payee, merchant_key(payee), "upi", vpa, ref)
        return _result(name, "upi", aliases, vpa=vpa, upi_ref=ref)

    if re.match(r"^(ATM|ATW|NWD|EAW)\b|ATM WDL|ATM CASH|CASH WDL|CASH WITHDRAWAL", upper):
        return Normalised("ATM withdrawal", "atm withdrawal", "atm", None, ref)

    if re.search(r"^(BY )?CASH\b|CASH DEP|CSH DEP|CASH DEPOSIT", upper):
        return Normalised("Cash deposit", "cash deposit", "cash", None, None)

    if re.match(r"^(POS|ECOM|ECM|PCD|VPS|IPS|ME DC|DC INTL|VIN|MPS)\b", upper) or "ECOM PUR" in upper:
        body = _CARD_NO.sub(" ", text)
        body = re.sub(
            r"(?i)^(pos|ecom pur|ecom|ecm|pcd|vps|ips|me dc si|me dc|dc intl pos txn|vin|mps)\b", "", body
        )
        tokens = _clean_tokens(re.split(r"[/|]+|\s{2,}", body))
        name = tokens[0] if tokens else None
        if name:
            words = [w for w in name.split() if merchant_key(w) not in _CITY_WORDS and not w.isdigit()]
            name = " ".join(words) or name
        return _result(name, "card", aliases, upi_ref=ref)

    for keyword, channel in (("NEFT", "neft"), ("RTGS", "neft"), ("IMPS", "imps")):
        if re.search(rf"\b{keyword}\b", upper):
            ch: Channel = "neft" if channel == "neft" else "imps"
            neft_ref = ref
            if ch == "neft" and (nm := _NEFT_REF.search(upper)):
                neft_ref = nm.group(1)  # the full UTR, e.g. N123456789012
            tokens = [
                t for t in _clean_tokens(_SPLIT.split(re.sub(r"(?i)\b(cr|dr)\b", " ", text)))
                if not _NEFT_REF.fullmatch(t.strip().upper())
            ]  # fmt: skip
            return _result(tokens[0] if tokens else None, ch, aliases, upi_ref=neft_ref)

    tokens = _clean_tokens(
        re.split(
            r"[/|]+|\s{2,}", re.sub(r"(?i)^(ach|nach|ecs|si|bil|inb)\b[ /-]*((dr|cr|d|c)\b[ /-]*)?", "", text)
        )
    )
    return _result(tokens[0] if tokens else None, "other", aliases, upi_ref=ref)
