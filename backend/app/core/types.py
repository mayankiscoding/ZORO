"""Cross-cutting enums.

Shared contract: mirrored in Swift (`ios/Packages/ZoroKit/Sources/ZoroCore`). Do not change a raw
value without updating `docs/architecture/design-spec.md` and the Swift mirror.
"""

from __future__ import annotations

from enum import StrEnum


class RiskLevel(StrEnum):
    LOW = "low"  # search, read, summarise, calculate, display
    MEDIUM = "medium"  # create a reminder, save a contact, change an approved setting
    HIGH = "high"  # send a message or email, modify sensitive records
    CRITICAL = "critical"  # payments, trades, account security, destructive deletion, sensitive export

    @property
    def rank(self) -> int:
        return ("low", "medium", "high", "critical").index(self.value)


class ApprovalLevel(StrEnum):
    NONE = "none"
    CONFIRM = "confirm"  # explicit tap, signed with the device auth key
    BIOMETRIC = "biometric"  # signed with the user-presence (Face ID / Touch ID) key


class PrivacyMode(StrEnum):
    STRICT_PRIVATE = "strict_private"
    CLOUD_INTELLIGENCE = "cloud_intelligence"


class DataClass(StrEnum):
    PUBLIC = "public"
    PERSONAL = "personal"
    SENSITIVE = "sensitive"
    FINANCIAL = "financial"
    HEALTH = "health"
    SECRET = "secret"  # noqa: S105 - credentials: never sent to any model, never stored in memory

    @property
    def rank(self) -> int:
        return {"public": 0, "personal": 1, "sensitive": 2, "financial": 3, "health": 3, "secret": 9}[
            self.value
        ]


class Locality(StrEnum):
    ON_DEVICE = "on_device"
    LOCAL = "local"  # same machine as the backend
    PRIVATE_NETWORK = "private_network"  # user-controlled host on the private network
    EXTERNAL = "external"  # third-party cloud


class DevicePlatform(StrEnum):
    IOS = "ios"
    MACOS = "macos"


class AgentId(StrEnum):
    SUPERVISOR = "supervisor"
    VOICE = "voice"
    PERSONAL_ASSISTANT = "personal_assistant"
    MEMORY = "memory"
    FINANCE = "finance"
    INVESTMENT = "investment"
    SHOPPING = "shopping"
    PRODUCT_RESEARCH = "product_research"
    VISION = "vision"
    COMMUNICATION = "communication"
    FITNESS = "fitness"
    MUSIC = "music"
    DEVICE_CONTROL = "device_control"
    DOCUMENT = "document"
    BROWSER_RESEARCH = "browser_research"
    AUTOMATION = "automation"
    SECURITY = "security"


class TaskClass(StrEnum):
    """What a model call is for. Routing maps a task class to models in config/models.yaml."""

    REALTIME_VOICE = "realtime_voice"
    INTENT_CLASSIFICATION = "intent_classification"
    ROUTINE_CHAT = "routine_chat"
    COMPLEX_REASONING = "complex_reasoning"
    CODING_RESEARCH = "coding_research"
    FINANCIAL_INTERPRETATION = "financial_interpretation"
    SUMMARIZATION = "summarization"
    EMBEDDING = "embedding"
    TTS = "tts"


class IntegrationLevel(StrEnum):
    """How a provider method is backed (design spec, shopping and integrations)."""

    FULLY_INTEGRATED = "fully_integrated"
    OFFICIAL_API = "official_api"
    AFFILIATE_SEARCH = "affiliate_search"
    DEEP_LINK_HANDOFF = "deep_link_handoff"
    MANUAL_FALLBACK = "manual_fallback"
    UNAVAILABLE = "unavailable"


class CapabilityStatus(StrEnum):
    WORKING_NATIVE = "working_native"  # public Apple API on the device
    WORKING_LOCAL = "working_local"  # runs on the private backend, no external party
    WORKING_INTEGRATION = "working_integration"  # official external API, credentials present
    REQUIRES_CREDENTIALS = "requires_credentials"
    REQUIRES_PARTNERSHIP = "requires_partnership"
    MANUAL_USER_STEP = "manual_user_step"  # hands off to another app or needs a tap
    RESTRICTED_BY_IOS = "restricted_by_ios"
    UNAVAILABLE = "unavailable"


class MemoryCategory(StrEnum):
    PROFILE = "profile"
    EPISODIC = "episodic"
    FINANCIAL = "financial"
    FITNESS = "fitness"
    VISUAL = "visual"
    KNOWLEDGE = "knowledge"
    CONVERSATION_STATE = "conversation_state"


class TurnStatus(StrEnum):
    RUNNING = "running"
    SUSPENDED = "suspended"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
