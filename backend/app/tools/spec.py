"""Tool contract: `ToolSpec` (static metadata the policy engine trusts) and `ToolContext`.

Risk, data classes, permission and the agent allowlist are fixed when a package registers a tool.
Nothing in a turn, and nothing a model writes, can change them.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime
from typing import TYPE_CHECKING, Any, Literal

from pydantic import BaseModel

from app.core.clock import Clock, SystemClock
from app.core.types import AgentId, DataClass, DevicePlatform, PrivacyMode, RiskLevel
from app.schemas.common import LabelValue, UICard
from app.tools.outcome import Completed, Denied, Failed, NeedsApproval, NeedsDeviceAction, ToolOutcome

if TYPE_CHECKING:
    from app.core.objects import ObjectStore
    from app.core.settings import Settings
    from app.db.session import SessionFactory
    from app.providers.gateway import ModelGateway  # type: ignore[import-not-found, unused-ignore]
    from app.security.audit import AuditLog
    from app.security.secrets import SecretStore
    from app.tools.state import ConversationStateStore

__all__ = [
    "ApprovalView",
    "Completed",
    "Denied",
    "Failed",
    "NeedsApproval",
    "NeedsDeviceAction",
    "ToolContext",
    "ToolHandler",
    "ToolOutcome",
    "ToolSpec",
]

ToolHandler = Callable[["ToolContext", Any], Awaitable[Any]]
"""``async (ctx, args: input_model) -> output_model`` (a dict is accepted and validated)."""

EventEmitter = Callable[[Any], Awaitable[None]]


@dataclass(frozen=True)
class ApprovalView:
    """What the owner sees before approving: who or what is affected and the exact content."""

    title: str
    summary: str
    details: tuple[LabelValue, ...] = ()


@dataclass(frozen=True)
class ToolSpec:
    name: str  # "<package>.<verb_noun>", e.g. "finance.spending_summary"
    description: str  # shown to models and MCP clients
    input_model: type[BaseModel]
    output_model: type[BaseModel]
    handler: ToolHandler | None  # None for device tools
    risk: RiskLevel
    data_classes: frozenset[DataClass]  # what the result may contain
    permission: str | None  # grant key, e.g. "finance.read"
    agents: frozenset[AgentId]  # allowlist
    mcp_group: str  # e.g. "finance-mcp"
    executor: Literal["backend", "device"] = "backend"
    device_platforms: frozenset[DevicePlatform] = frozenset()
    timeout_s: float = 20
    rate_limit_per_min: int = 60
    untrusted_output: bool = False
    summarizer: Callable[[Any, str], str] | None = None  # (result, "en"|"hi"|"hinglish") -> sentence
    card: Callable[[Any], UICard | None] | None = None
    approval_view: Callable[[Any], ApprovalView] | None = None  # (validated args) -> what to show


@dataclass
class ToolContext:
    """Everything a tool handler may use. Built by the orchestrator per call; the flags
    `tainted` and `user_initiated` come from the turn, never from model output."""

    turn_id: str
    agent: AgentId
    db: SessionFactory
    settings: Settings
    audit: AuditLog
    secrets: SecretStore
    objects: ObjectStore
    conversation_id: str | None = None
    device_id: str | None = None  # the requesting device; None for system-initiated work
    privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE
    lang: str = "en"  # "en" | "hi" | "hinglish"
    timezone: str = "Asia/Kolkata"
    tainted: bool = False
    user_initiated: bool = False
    gateway: ModelGateway | None = None
    clock: Clock = field(default_factory=SystemClock)
    emitter: EventEmitter | None = None
    state: ConversationStateStore | None = None  # temporary conversation state (working sets)
    # Where a device tool should run: an explicit paired device, or a platform the owner named
    # ("on my Mac"). Set by the orchestrator from intent slots or a follow-up, never by a model.
    target_device_id: str | None = None
    target_platform: DevicePlatform | None = None

    async def working_set(self, kind: str) -> list[dict[str, Any]]:
        """Items last shown to the owner in this conversation (e.g. "products"), in display order."""
        if self.state is None or self.conversation_id is None:
            return []
        return await self.state.working_set(self.conversation_id, kind)

    async def set_working_set(self, kind: str, items: list[dict[str, Any]]) -> None:
        """Remember what was just shown so "the second one" resolves on the next turn."""
        if self.state is not None and self.conversation_id is not None:
            await self.state.set_working_set(self.conversation_id, kind, items)

    def now(self) -> datetime:
        return self.clock.now()

    async def emit(self, event: Any) -> None:
        """Send a turn event (`app.schemas.turns`) to the client stream, when one is attached."""
        if self.emitter is not None:
            await self.emitter(event)

    def mark_tainted(self) -> None:
        """One way only: a turn that has seen untrusted content stays tainted."""
        self.tainted = True
