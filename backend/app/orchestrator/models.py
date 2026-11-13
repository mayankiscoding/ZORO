"""Conversations, messages and turns. Owner-authored text and replies are encrypted at rest."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime
from app.db.types import JSONType


class ConversationRow(Base):
    __tablename__ = "orchestrator_conversations"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    title_enc: Mapped[str] = mapped_column(Text)
    preview_enc: Mapped[str] = mapped_column(Text)
    message_count: Mapped[int] = mapped_column(Integer, default=0)
    last_agent: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_by_device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)


class MessageRow(Base):
    __tablename__ = "orchestrator_messages"
    __table_args__ = (UniqueConstraint("conversation_id", "seq"),)

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    conversation_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("orchestrator_conversations.id", ondelete="CASCADE"), index=True
    )
    turn_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    seq: Mapped[int] = mapped_column(Integer)
    role: Mapped[str] = mapped_column(String(16))  # user | assistant
    text_enc: Mapped[str] = mapped_column(Text)
    cards_enc: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON list of UICard, encrypted
    language: Mapped[str] = mapped_column(String(16), default="en")
    agents: Mapped[list[Any]] = mapped_column(JSONType, default=list)
    data_classes: Mapped[list[Any]] = mapped_column(JSONType, default=list)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)


class TurnRow(Base):
    __tablename__ = "orchestrator_turns"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    conversation_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("orchestrator_conversations.id", ondelete="CASCADE"), index=True
    )
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    status: Mapped[str] = mapped_column(String(16), index=True)  # TurnStatus
    privacy_mode: Mapped[str] = mapped_column(String(32))
    language: Mapped[str] = mapped_column(String(16), default="en")
    pending_kind: Mapped[str | None] = mapped_column(String(16), nullable=True)  # approval | device_action
    pending_ref: Mapped[str | None] = mapped_column(String(64), nullable=True)  # approval id / action id
    error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    message_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    usage: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)
