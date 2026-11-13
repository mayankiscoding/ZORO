"""ORM model for model-usage events (one row per provider call attempt)."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, Boolean, Float, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime, new_id, utcnow


class UsageEvent(Base):
    __tablename__ = "model_usage_events"

    id: Mapped[str] = mapped_column(String(40), primary_key=True, default=lambda: new_id("use"))
    ts: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)
    provider: Mapped[str] = mapped_column(String(64), index=True)
    model: Mapped[str] = mapped_column(String(128), index=True)  # model id from config
    task: Mapped[str] = mapped_column(String(48), index=True)
    agent: Mapped[str | None] = mapped_column(String(48), nullable=True)
    turn_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    input_tokens: Mapped[int] = mapped_column(Integer, default=0)
    output_tokens: Mapped[int] = mapped_column(Integer, default=0)
    audio_seconds: Mapped[float] = mapped_column(Float, default=0.0)
    latency_ms: Mapped[int] = mapped_column(Integer, default=0)
    cost_micro_usd: Mapped[int] = mapped_column(BigInteger, default=0)  # integer micro-USD, never float
    error: Mapped[bool] = mapped_column(Boolean, default=False)
    error_kind: Mapped[str | None] = mapped_column(String(32), nullable=True)
