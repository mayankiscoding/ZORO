"""JSON logging with a redacting filter.

Nothing sensitive may reach a log line: secret-looking keys in `extra` are masked and common
secret / identifier shapes inside messages are replaced. This is a safety net; callers still must
not log raw payloads.
"""

from __future__ import annotations

import json
import logging
import re
import sys
from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

MASK = "[redacted]"

_SENSITIVE_KEY = re.compile(
    r"(pass(word|wd|code)?|secret|token|authori[sz]ation|api[_-]?key|signature|private[_-]?key|"
    r"credential|cookie|otp|pin|cvv|pairing[_-]?code|nonce|data[_-]?key)",
    re.IGNORECASE,
)

_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"), f"Bearer {MASK}"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b"), MASK),  # JWT
    (
        re.compile(
            r"(?i)\b(password|passwd|secret|token|api[_-]?key|otp|pin|cvv|signature)\b(\s*[=:]\s*)"
            r"(\"[^\"]*\"|'[^']*'|[^\s,;&]+)"
        ),
        rf"\1\2{MASK}",
    ),
    (re.compile(r"\b[A-Z]{5}[0-9]{4}[A-Z]\b"), MASK),  # PAN
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"), MASK),  # email
    (re.compile(r"\b[\w.-]{2,}@[a-zA-Z]{2,}\b"), MASK),  # UPI id
    (re.compile(r"(?<![\w.])(?:\d[ -]?){12,19}(?![\w])"), MASK),  # Aadhaar, card and account numbers
    (re.compile(r"(?<![\w.])(?:\+91[ -]?)?[6-9]\d{9}(?!\w)"), MASK),  # Indian mobile numbers
)

_RESERVED = frozenset(logging.LogRecord("x", 0, "x", 0, "", None, None).__dict__) | {"message", "asctime"}


def redact_text(text: str) -> str:
    """Mask secret and identifier shapes inside free text."""
    for pattern, replacement in _PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def redact_value(value: Any, *, key: str | None = None) -> Any:
    """Mask a structured value: sensitive keys entirely, strings by pattern, containers recursively."""
    if key is not None and _SENSITIVE_KEY.search(key):
        return MASK
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, bytes | bytearray):
        return MASK
    if isinstance(value, Mapping):
        return {str(k): redact_value(v, key=str(k)) for k, v in value.items()}
    if isinstance(value, list | tuple | set | frozenset):
        return [redact_value(item) for item in value]
    return value


class RedactingFilter(logging.Filter):
    """Rewrites the record in place before any handler formats it."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:  # a malformed format string must not break logging
            message = str(record.msg)
        record.msg = redact_text(message)
        record.args = None
        for key, value in list(record.__dict__.items()):
            if key in _RESERVED:
                continue
            record.__dict__[key] = redact_value(value, key=key)
        return True


#: Query parameters whose value never reaches a log line (the device channel's `?token=` above all).
SENSITIVE_QUERY_PARAMS = frozenset(
    {"token", "access_token", "id_token", "refresh_token", "code", "state", "key", "api_key", "signature"}
)


def redact_url(url: str) -> str:
    """Mask sensitive query parameter values in a path or URL, keeping everything else readable."""
    if "?" not in url:
        return url
    parts = urlsplit(url)
    pairs = parse_qsl(parts.query, keep_blank_values=True)
    masked = [
        (k, MASK if k.lower() in SENSITIVE_QUERY_PARAMS or _SENSITIVE_KEY.search(k) else v) for k, v in pairs
    ]
    return urlunsplit(parts._replace(query=urlencode(masked, safe="[]")))


class AccessLogRedactor(logging.Filter):
    """For ``uvicorn.access``: rewrites the request path inside ``record.args``.

    Uvicorn's access formatter unpacks ``(client, method, path, http_version, status)`` from
    ``record.args``, so the generic `RedactingFilter` (which clears ``args``) cannot be used there.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if isinstance(args, tuple):
            record.args = tuple(
                redact_text(redact_url(a)) if isinstance(a, str) and i == 2 else a for i, a in enumerate(args)
            )
        elif isinstance(record.msg, str):
            record.msg = redact_text(record.msg)
        return True


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info and record.exc_info[0] is not None:
            payload["exc_type"] = record.exc_info[0].__name__
            payload["exc"] = redact_text(self.formatException(record.exc_info))
        return json.dumps(payload, default=str, ensure_ascii=False)


def configure_logging(level: str = "INFO") -> None:
    """Install one JSON handler with the redacting filter on the root logger (idempotent)."""
    root = logging.getLogger()
    root.setLevel(level.upper())
    for handler in root.handlers:
        if getattr(handler, "_zoro", False):
            handler.setLevel(level.upper())
            return
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(JsonFormatter())
    handler.addFilter(RedactingFilter())
    handler._zoro = True  # type: ignore[attr-defined]
    root.addHandler(handler)
    access = logging.getLogger("uvicorn.access")
    for existing in list(access.filters):
        if isinstance(existing, RedactingFilter | AccessLogRedactor):
            access.removeFilter(existing)
    access.addFilter(AccessLogRedactor())


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(name)
