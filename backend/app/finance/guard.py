"""Never accept a UPI PIN, OTP, password or CVV: any request that carries such a field is refused
before it reaches a handler, and its value is neither stored nor logged."""

from __future__ import annotations

import contextlib
import json
import re
from typing import Any

from starlette.requests import Request

from app.core.errors import BadRequest

FORBIDDEN_TOKENS = frozenset({
    "pin", "upipin", "mpin", "atmpin", "tpin", "otp", "totp", "password", "passwd", "pwd", "passcode",
    "cvv", "cvv2", "cvc", "cvc2", "cardcvv", "netbankingpassword", "loginpassword",
})  # fmt: skip
_SPLIT = re.compile(r"[^a-z0-9]+")


class ForbiddenField(BadRequest):
    code = "forbidden_field"
    default_message = "ZORO never accepts a UPI PIN, OTP, password or CVV. Remove that field and try again."


def is_forbidden(key: str) -> bool:
    low = key.lower()
    if _SPLIT.sub("", low) in FORBIDDEN_TOKENS:
        return True
    camel = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", key).lower()
    return any(token in FORBIDDEN_TOKENS for token in _SPLIT.split(camel) if token)


def forbidden_keys(value: Any, prefix: str = "") -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, inner in value.items():
            path = f"{prefix}.{key}" if prefix else str(key)
            if is_forbidden(str(key)):
                found.append(path)
            found.extend(forbidden_keys(inner, path))
    elif isinstance(value, list):
        for index, inner in enumerate(value):
            found.extend(forbidden_keys(inner, f"{prefix}[{index}]"))
    return found


async def reject_secret_fields(request: Request) -> None:
    """Router dependency: query names, JSON keys (any depth) and multipart / form field names."""
    found = [k for k in request.query_params if is_forbidden(k)]
    content_type = request.headers.get("content-type", "")
    if request.method in ("POST", "PUT", "PATCH"):
        if content_type.startswith("application/json"):
            body = await request.body()
            if body:
                with contextlib.suppress(ValueError):  # malformed JSON is rejected by validation later
                    found += forbidden_keys(json.loads(body))
        elif content_type.startswith(("multipart/form-data", "application/x-www-form-urlencoded")):
            form = await request.form()
            found += [k for k in form if is_forbidden(k)]
    if found:
        raise ForbiddenField(detail={"fields": sorted(set(found))})
