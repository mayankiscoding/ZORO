"""Conversation turn contract: request, server-sent events, approvals and device actions.

`POST /v1/turns` and `POST /v1/turns/{turn_id}/resume` answer with `text/event-stream`.
Each SSE frame is ``event: <type>`` + ``data: <json of the event model>``.
A turn that needs an approval or a device action emits that event, then `turn_suspended`, and the
stream ends. The client resumes it with `ResumeRequest`.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Annotated, Any, Literal

from pydantic import AwareDatetime, Field

from app.core.types import (
    AgentId,
    ApprovalLevel,
    CapabilityStatus,
    DataClass,
    DevicePlatform,
    PrivacyMode,
    RiskLevel,
)
from app.schemas.common import LabelValue, UICard, ZModel

# ---------------------------------------------------------------- request


class TurnInput(ZModel):
    text: str
    modality: Literal["text", "voice"] = "text"
    language_hint: str | None = None  # "en" | "hi" | "hinglish"


class ClientContext(ZModel):
    platform: DevicePlatform
    locale: str = "en-IN"
    timezone: str = "Asia/Kolkata"
    location_ref: str | None = None  # opaque reference to a saved place, never raw coordinates
    capabilities: list[str] = Field(default_factory=list)
    app_state: dict[str, Any] = Field(default_factory=dict)  # e.g. {"selected_product_ref": "..."}


class TurnRequest(ZModel):
    conversation_id: str | None = None
    input: TurnInput
    client: ClientContext
    privacy_mode: PrivacyMode | None = None  # may only be stricter than the server setting


# ---------------------------------------------------------------- approvals


class ApprovalRequest(ZModel):
    approval_id: str
    turn_id: str | None = None
    tool: str
    agent: AgentId | None = None
    risk: RiskLevel
    level: ApprovalLevel
    title: str  # e.g. "Send email to hr@example.com"
    summary: str  # the exact content that will be acted on
    details: list[LabelValue] = Field(default_factory=list)
    action_digest: str  # hex SHA-256 the server computed over the canonical {tool, args}
    expires_at: AwareDatetime
    tainted: bool = False  # the turn had seen untrusted content when this was requested


class ApprovalDecisionResult(ZModel):
    """Answer of `POST /v1/approvals/{approval_id}/decision`.

    `owner` says who was waiting: a suspended conversation turn ("turn": `events` holds the
    resumed turn's events, in order, ending in `turn_completed`, `turn_suspended` or `error`),
    an MCP call ("mcp") or an automation run ("automation": `run_id`). `status` is the owner's
    own word for what happened next (for example "completed", "suspended", "denied", "running").
    """

    approval_id: str
    owner: str
    approved: bool
    status: str
    turn_id: str | None = None
    run_id: str | None = None
    events: list[dict[str, Any]] = Field(default_factory=list)
    result: dict[str, Any] | None = None


class ApprovalDecision(ZModel):
    """`signature_b64` signs ``zoro-approval-v1|{approval_id}|{action_digest}|{1 or 0}|{signed_at}``.

    `level == biometric` must be signed with the approval (user-presence) key, otherwise the auth key.
    """

    approval_id: str
    approved: bool
    action_digest: str
    device_id: str
    signed_at: AwareDatetime
    signature_b64: str


# ---------------------------------------------------------------- device actions


class DeviceActionRequest(ZModel):
    action_id: str
    turn_id: str | None = None
    target_device_id: str | None = None
    tool: str  # e.g. "ios.alarm.create"
    args: dict[str, Any] = Field(default_factory=dict)
    risk: RiskLevel
    requires_user_confirmation: bool = False
    expires_at: AwareDatetime


class DeviceActionResult(ZModel):
    action_id: str
    ok: bool
    result: dict[str, Any] | None = None
    # permission_denied | unsupported | user_cancelled | invalid_arguments | expired | failed
    error_code: str | None = None
    error_message: str | None = None
    capability_status: CapabilityStatus | None = None
    executed_at: AwareDatetime


class ResumeRequest(ZModel):
    approval: ApprovalDecision | None = None
    device_result: DeviceActionResult | None = None


# ---------------------------------------------------------------- events


class UsageSummary(ZModel):
    model_calls: int = 0
    tool_calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: Decimal = Decimal("0")
    duration_ms: int = 0


class TurnStarted(ZModel):
    type: Literal["turn_started"] = "turn_started"
    turn_id: str
    conversation_id: str
    privacy_mode: PrivacyMode


class RouteDecided(ZModel):
    type: Literal["route"] = "route"
    agents: list[AgentId]
    reason: str
    data_classes: list[DataClass]
    engine: Literal["deterministic", "local_model", "cloud_model"]


class AgentStarted(ZModel):
    type: Literal["agent_started"] = "agent_started"
    agent: AgentId
    task: str


class AgentFinished(ZModel):
    type: Literal["agent_finished"] = "agent_finished"
    agent: AgentId
    ok: bool
    duration_ms: int


class ToolStarted(ZModel):
    type: Literal["tool_started"] = "tool_started"
    call_id: str
    tool: str
    agent: AgentId
    risk: RiskLevel


class ToolFinished(ZModel):
    type: Literal["tool_finished"] = "tool_finished"
    call_id: str
    ok: bool
    duration_ms: int
    summary: str | None = None


class TextDelta(ZModel):
    type: Literal["text_delta"] = "text_delta"
    text: str


class CardEvent(ZModel):
    type: Literal["card"] = "card"
    card: UICard


class ApprovalRequired(ZModel):
    type: Literal["approval_required"] = "approval_required"
    approval: ApprovalRequest


class DeviceActionEvent(ZModel):
    type: Literal["device_action"] = "device_action"
    action: DeviceActionRequest


class TurnSuspended(ZModel):
    type: Literal["turn_suspended"] = "turn_suspended"
    turn_id: str
    reason: Literal["approval", "device_action"]


class TurnCompleted(ZModel):
    type: Literal["turn_completed"] = "turn_completed"
    turn_id: str
    message_id: str
    language: str  # "en" | "hi" | "hinglish"
    data_classes: list[DataClass]
    cloud_voice_allowed: bool  # false: the app must speak this reply with the on-device voice
    usage: UsageSummary


class TurnError(ZModel):
    type: Literal["error"] = "error"
    code: str
    message: str
    retryable: bool = False


TurnEvent = Annotated[
    TurnStarted
    | RouteDecided
    | AgentStarted
    | AgentFinished
    | ToolStarted
    | ToolFinished
    | TextDelta
    | CardEvent
    | ApprovalRequired
    | DeviceActionEvent
    | TurnSuspended
    | TurnCompleted
    | TurnError,
    Field(discriminator="type"),
]

# ---------------------------------------------------------------- device channel (WebSocket)
# GET /v1/devices/channel — JSON text frames:
#   server -> device: {"type": "device_action", "action": DeviceActionRequest}
#                     {"type": "approval_required", "approval": ApprovalRequest}
#   device -> server: {"type": "hello", "capabilities": [...]}
#                     {"type": "device_action_result", "result": DeviceActionResult}
#                     {"type": "ping"}
