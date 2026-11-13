"""Tool-call journal: suspended calls (waiting for an approval or a device) and the recorded
outcome of side-effecting calls, so a `call_id` runs at most once."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, UTCDateTime


class ToolCallRow(Base):
    __tablename__ = "kernel_tool_calls"

    call_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    turn_id: Mapped[str] = mapped_column(String(64), index=True)
    tool: Mapped[str] = mapped_column(String(200))
    agent: Mapped[str] = mapped_column(String(64))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)  # the requesting device
    args_enc: Mapped[str] = mapped_column(Text)  # canonical JSON of the validated arguments, encrypted
    action_digest: Mapped[str] = mapped_column(String(64))
    # awaiting_approval | awaiting_device | running | done
    state: Mapped[str] = mapped_column(String(24))
    approval_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    action_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    target_device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    device_request_enc: Mapped[str | None] = mapped_column(Text, nullable=True)
    outcome_enc: Mapped[str | None] = mapped_column(Text, nullable=True)  # final outcome, encrypted
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)


class ConversationStateRow(Base):
    """Temporary per-conversation state (working sets); see `app.tools.state`."""

    __tablename__ = "kernel_conversation_state"

    conversation_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    key: Mapped[str] = mapped_column(String(120), primary_key=True)
    value_enc: Mapped[str] = mapped_column(Text)  # JSON, encrypted
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
