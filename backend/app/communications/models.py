"""ORM: message drafts. Recipient address, subject and text are sealed at rest (AES-256-GCM)."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime


class MessageDraftRow(Base):
    __tablename__ = "communications_drafts"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    channel: Mapped[str] = mapped_column(String(16))  # whatsapp | sms | imessage | email
    recipient_ref: Mapped[str | None] = mapped_column(String(200), nullable=True)  # device contact reference
    recipient_display: Mapped[str] = mapped_column(String(200))
    address_enc: Mapped[str] = mapped_column(Text)  # phone digits or email address
    subject_enc: Mapped[str | None] = mapped_column(Text, nullable=True)
    text_enc: Mapped[str] = mapped_column(Text)
    language: Mapped[str] = mapped_column(String(12))  # en | hi | hinglish
    status: Mapped[str] = mapped_column(String(16), index=True)  # draft | sent | handed_off | discarded
    external_id: Mapped[str | None] = mapped_column(String(200), nullable=True)  # Gmail draft / message id
    conversation_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)
    sent_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
