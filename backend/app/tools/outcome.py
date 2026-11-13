"""What a tool call can come to. `ToolOutcome` is the union the orchestrator switches on."""

from __future__ import annotations

from dataclasses import dataclass, field

from pydantic import BaseModel

from app.core.types import DataClass
from app.schemas.common import UICard
from app.schemas.turns import ApprovalRequest, DeviceActionRequest
from app.tools.followup import FollowUp


@dataclass(frozen=True)
class Completed:
    """The tool ran and its result validated against `output_model`.

    `model_text` is what may be shown to a model: the result as JSON, wrapped in
    ``<untrusted source="…">`` when the tool's output is untrusted (then `untrusted` is true and
    the executor has already marked the turn tainted). Never put it in the system role.
    """

    result: BaseModel
    call_id: str = field(default="", kw_only=True)
    tool: str = field(default="", kw_only=True)
    data_classes: frozenset[DataClass] = field(default_factory=frozenset, kw_only=True)
    untrusted: bool = field(default=False, kw_only=True)
    model_text: str = field(default="", kw_only=True)
    summary: str | None = field(default=None, kw_only=True)  # from ToolSpec.summarizer
    card: UICard | None = field(default=None, kw_only=True)  # from ToolSpec.card
    duration_ms: int = field(default=0, kw_only=True)
    # Next steps the tool handed over (`app.tools.followup`). The orchestrator runs each through
    # the executor as an ordinary call; nothing here is executed by the executor itself.
    follow_ups: tuple[FollowUp, ...] = field(default=(), kw_only=True)
    # False: this result must never be placed in an external model's prompt (local models only).
    external_model_allowed: bool = field(default=True, kw_only=True)


@dataclass(frozen=True)
class NeedsApproval:
    """Suspend the turn; resume with `ToolExecutor.resume_with_approval`."""

    request: ApprovalRequest
    call_id: str = field(default="", kw_only=True)
    tool: str = field(default="", kw_only=True)


@dataclass(frozen=True)
class NeedsDeviceAction:
    """The requesting device must run this; resume with `ToolExecutor.resume_with_device_result`."""

    request: DeviceActionRequest
    call_id: str = field(default="", kw_only=True)
    tool: str = field(default="", kw_only=True)


@dataclass(frozen=True)
class Denied:
    """Policy said no. `reason` is a stable code: kill_switch, device_revoked, device_unknown,
    agent_not_allowed, permission_not_granted:<key>, rate_limited, unknown_tool, approval_declined,
    or an approval error code (approval_expired, approval_replayed, invalid_signature, …)."""

    reason: str
    call_id: str = field(default="", kw_only=True)
    tool: str = field(default="", kw_only=True)
    message: str = field(default="", kw_only=True)


@dataclass(frozen=True)
class Failed:
    """The call could not complete. `error` is a stable code: invalid_arguments, timeout,
    tool_error, invalid_result, device_offline (nothing was delivered: may be retried),
    device_timeout (delivered, outcome unknown: never retried automatically), device_unavailable,
    call_not_found, …"""

    error: str
    call_id: str = field(default="", kw_only=True)
    tool: str = field(default="", kw_only=True)
    message: str = field(default="", kw_only=True)
    retryable: bool = field(default=False, kw_only=True)


ToolOutcome = Completed | NeedsApproval | NeedsDeviceAction | Denied | Failed
