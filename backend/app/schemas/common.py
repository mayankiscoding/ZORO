"""Shared API contract pieces. JSON is snake_case; money is a decimal string; times are ISO-8601 UTC."""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from typing import Any, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field


class ZModel(BaseModel):
    """Base for every API contract model."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)


class Money(ZModel):
    amount: Decimal  # JSON: string, e.g. "1234.50"
    currency: str = "INR"


class LabelValue(ZModel):
    label: str
    value: str


class Page[T](ZModel):
    items: list[T]
    next_cursor: str | None = None


class SignedProof(ZModel):
    """Proof that a registered device (and, for the approval key, its owner) authorised an action.

    Signed bytes (UTF-8): ``zoro-action-v1|{action}|{subject}|{signed_at}`` where ``signed_at`` is
    formatted ``YYYY-MM-DDTHH:MM:SSZ``. ECDSA P-256 / SHA-256, DER signature, base64.
    The server accepts a clock skew of 120 s and rejects replays.
    """

    device_id: str
    signed_at: AwareDatetime
    signature_b64: str
    key: Literal["approval", "auth"] = "approval"  # approval = user-presence key


class UICard(ZModel):
    """A structured result the app renders natively. `payload` is the domain DTO for `kind`."""

    kind: str  # products | basket | basket_comparison | finance_summary | transactions | portfolio |
    # stock_analysis | fitness_summary | photo_query | music | message_draft | memory | sources |
    # capability_notice
    title: str | None = None
    payload: dict[str, Any] = Field(default_factory=dict)


class ErrorBody(ZModel):
    code: str
    message: str
    retryable: bool = False
    detail: dict[str, Any] | None = None


def iso_seconds(ts: datetime) -> str:
    """Canonical timestamp used inside signed strings."""
    return ts.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
