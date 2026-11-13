"""Memory, conversation and voice contract."""

from __future__ import annotations

from typing import Literal

from pydantic import AwareDatetime, Field

from app.core.types import AgentId, DataClass, MemoryCategory
from app.schemas.common import SignedProof, UICard, ZModel

# ---------------------------------------------------------------- memory


class MemoryRecord(ZModel):
    id: str
    category: MemoryCategory
    text: str
    source: str  # e.g. "conversation:conv_…", "user", "statement:HDFC-2026-10"
    confidence: float = Field(ge=0, le=1)
    sensitivity: DataClass
    status: Literal["active", "pending_review", "archived"] = "active"
    user_editable: bool = True
    created_at: AwareDatetime
    last_verified_at: AwareDatetime | None = None
    expires_at: AwareDatetime | None = None


class MemoryCreate(ZModel):
    category: MemoryCategory
    text: str
    sensitivity: DataClass = DataClass.PERSONAL


class MemoryPatch(ZModel):
    text: str | None = None
    status: Literal["active", "pending_review", "archived"] | None = None
    verified: bool | None = None  # true stamps last_verified_at


class MemoryCategorySetting(ZModel):
    category: MemoryCategory
    enabled: bool
    retention_days: int | None = None  # None = keep until deleted


class MemorySettings(ZModel):
    categories: list[MemoryCategorySetting]
    conversation_retention_days: int


class MemoryExportRequest(ZModel):
    """Signed subject: ``all`` or a category value. Action name: ``export_memory``."""

    category: MemoryCategory | None = None
    proof: SignedProof


class MemoryDeleteCategoryRequest(ZModel):
    """Signed subject: the category value. Action name: ``delete_memory_category``."""

    proof: SignedProof


# ---------------------------------------------------------------- conversations


class ConversationSummary(ZModel):
    id: str
    title: str
    updated_at: AwareDatetime
    last_message_preview: str = ""
    message_count: int = 0


class Message(ZModel):
    id: str
    role: Literal["user", "assistant"]
    text: str
    language: str = "en"
    created_at: AwareDatetime
    agents: list[AgentId] = Field(default_factory=list)
    cards: list[UICard] = Field(default_factory=list)


# ---------------------------------------------------------------- voice


class VoiceSettings(ZModel):
    personality: Literal["calm", "warm", "crisp"] = "warm"
    voice_gender: Literal["female", "male", "neutral"] = "female"
    speaking_rate: float = Field(default=1.0, ge=0.5, le=2.0)
    language: Literal["auto", "en", "hi", "hinglish"] = "auto"
    engine: Literal["local", "cloud"] = "local"
    response_length: Literal["brief", "balanced", "detailed"] = "brief"
    activation: Literal["button", "hold_to_talk", "wake_word_in_session"] = "button"
    voice_id: str | None = None


class VoiceOption(ZModel):
    id: str
    name: str
    engine: str  # on_device | gemini_live | gemini_tts | elevenlabs | google_chirp
    gender: str
    languages: list[str]


class VoiceEngineStatus(ZModel):
    id: str
    available: bool
    reason: str = ""


class VoiceConfig(ZModel):
    settings: VoiceSettings
    engines: list[VoiceEngineStatus]
    voices: list[VoiceOption]


class LiveSessionGrant(ZModel):
    """Short-lived grant so the device talks to the realtime voice provider without holding its key."""

    provider: str
    model: str
    ws_url: str
    ephemeral_token: str
    expires_at: AwareDatetime
    system_instruction: str
    input_sample_rate: int = 16000
    output_sample_rate: int = 24000


class TTSRequest(ZModel):
    text: str
    language: Literal["en", "hi", "hinglish"] = "en"
    voice_id: str | None = None
