"""Identifiers, random tokens and canonical hashing used across the kernel."""

from __future__ import annotations

import hashlib
import json
import secrets
from typing import Any

from app.db.base import new_id

__all__ = ["canonical_json", "new_id", "new_token", "sha256_hex"]


def new_token(nbytes: int = 32) -> str:
    """URL-safe random token with `nbytes` of entropy."""
    return secrets.token_urlsafe(nbytes)


def canonical_json(value: Any) -> str:
    """Deterministic JSON: sorted keys, no whitespace, UTF-8 kept as is.

    The input must already be JSON-native (use `model_dump(mode="json")` for Pydantic models), so
    that the same logical value always hashes to the same digest. Floats are refused where they
    would be ambiguous (NaN / infinity).
    """
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def sha256_hex(data: str | bytes) -> str:
    raw = data.encode("utf-8") if isinstance(data, str) else data
    return hashlib.sha256(raw).hexdigest()
