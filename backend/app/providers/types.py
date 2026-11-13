"""Request, response and error types of the model gateway.

A request names a `TaskClass`, never a model: routing to concrete models lives in config/models.yaml.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.core.types import AgentId, DataClass, Locality, PrivacyMode, TaskClass

Role = Literal["system", "user", "assistant", "tool"]
ErrorKind = Literal["rate_limited", "auth", "timeout", "unavailable", "bad_request", "blocked"]


class _Frozen(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class ToolCall(_Frozen):
    id: str
    name: str
    arguments: dict[str, Any] = Field(default_factory=dict)
    #: Opaque provider token that must be echoed back with this call (Gemini `thoughtSignature`).
    signature: str | None = None


class ChatMessage(_Frozen):
    role: Role
    content: str = ""
    tool_calls: tuple[ToolCall, ...] = ()
    tool_call_id: str | None = None  # role == "tool": the call this result answers
    name: str | None = None  # role == "tool": the tool name (Gemini needs it; looked up if missing)


class ToolDef(_Frozen):
    name: str
    description: str
    parameters: dict[str, Any] = Field(default_factory=lambda: {"type": "object", "properties": {}})


class Usage(_Frozen):
    input_tokens: int = 0
    output_tokens: int = 0
    audio_seconds: float = 0.0


class ChatRequest(_Frozen):
    task: TaskClass
    messages: tuple[ChatMessage, ...]
    tools: tuple[ToolDef, ...] = ()
    response_schema: dict[str, Any] | None = None  # JSON Schema; the reply is parsed into `parsed`
    max_output_tokens: int = 1024
    temperature: float | None = None
    #: Data classes of everything in the prompt. Empty means unknown and is treated as PERSONAL.
    data_classes: frozenset[DataClass] = frozenset()
    privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE
    agent: AgentId | None = None
    turn_id: str | None = None
    timeout_s: float = 30.0


class ChatResponse(_Frozen):
    text: str = ""
    tool_calls: tuple[ToolCall, ...] = ()
    parsed: Any = None
    usage: Usage = Usage()
    provider: str = ""
    model: str = ""  # model id from config, not the vendor model name
    #: Where the answering provider runs (set by the gateway; None for scripted or unknown replies).
    locality: Locality | None = None
    latency_ms: int = 0
    finish_reason: str = "stop"  # stop | length | tool_calls | content_filter | other

    @property
    def external(self) -> bool:
        """True when a third-party cloud provider produced this reply."""
        return self.locality is Locality.EXTERNAL


class ChatChunk(_Frozen):
    """One streamed piece. The last chunk has `done=True` and carries usage and finish reason."""

    delta: str = ""
    tool_calls: tuple[ToolCall, ...] = ()  # complete calls, emitted once assembled
    done: bool = False
    finish_reason: str | None = None
    usage: Usage | None = None
    provider: str = ""
    model: str = ""
    locality: Locality | None = None


class EmbeddingResult(_Frozen):
    model: str  # model id from config, or "local-hash-v1"
    dims: int
    vectors: tuple[tuple[float, ...], ...]


class ProviderError(Exception):
    """A provider call failed. `kind` drives retry, breaker and fallback decisions."""

    def __init__(self, kind: ErrorKind, message: str = "", *, retry_after_s: float | None = None) -> None:
        super().__init__(f"{kind}: {message}" if message else kind)
        self.kind: ErrorKind = kind
        self.message = message
        self.retry_after_s = retry_after_s

    @property
    def retryable(self) -> bool:
        return self.kind in ("rate_limited", "timeout", "unavailable")


class NoPermittedModel(Exception):
    """No configured, enabled model may receive this data. Callers fall back to deterministic code."""

    def __init__(self, task: TaskClass, reasons: dict[str, str] | None = None) -> None:
        self.task = task
        self.reasons = dict(reasons or {})
        detail = ", ".join(f"{k}={v}" for k, v in sorted(self.reasons.items())) or "no_enabled_model"
        super().__init__(f"no permitted model for {task.value}: {detail}")


class EgressDenied(NoPermittedModel):
    """Enabled models exist for the task but the egress policy refused every one of them."""
