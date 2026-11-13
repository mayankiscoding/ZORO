"""ORM: the owner's voice settings (one row)."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime


class VoiceSettingsRow(Base):
    __tablename__ = "voice_settings"

    key: Mapped[str] = mapped_column(String(32), primary_key=True)  # always "default"
    value: Mapped[dict[str, object]] = mapped_column(JSON)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)
