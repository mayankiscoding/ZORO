"""Agent contract: `AgentSpec` (static description of one specialist) and the catalog.

An agent's tools are never listed here. They are exactly the registry tools whose
`ToolSpec.agents` contains the agent, so a package grants a tool to an agent in one place and
nothing an agent (or a model) says can widen it.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass, field
from typing import Literal

from pydantic import BaseModel, Field

from app.core.types import AgentId, DataClass, TaskClass
from app.tools.registry import ToolRegistry
from app.tools.spec import ToolSpec


class AgentTask(BaseModel):
    """What every specialist receives: the owner's words and where they came from."""

    text: str
    lang: Literal["en", "hi", "hinglish"] = "en"
    intent: str | None = None  # the registered intent that matched, when routing was deterministic


class AgentReply(BaseModel):
    """What every specialist returns to the supervisor."""

    text: str = ""
    data_classes: list[DataClass] = Field(default_factory=list)
    ok: bool = True


class RoutingDecision(BaseModel):
    """Structured output of the supervisor's routing call."""

    agent: AgentId
    intent: str | None = None
    confidence: float = Field(default=0.5, ge=0, le=1)


@dataclass(frozen=True)
class RetryPolicy:
    """Retries of a failed model call inside one agent run (the gateway already retries transport
    errors and falls back across models; this is the agent's own, smaller budget)."""

    max_attempts: int = 2
    backoff_s: float = 0.2


@dataclass(frozen=True)
class FallbackPolicy:
    """What the agent does when no model may see the data, or the model keeps failing.

    `deterministic`: answer from the tools' summarizer sentences (or say plainly that nothing
    could be done). `decline`: say that this needs a model and stop.
    """

    on_no_model: Literal["deterministic", "decline"] = "deterministic"
    on_model_error: Literal["deterministic", "decline"] = "deterministic"


@dataclass(frozen=True)
class AgentSpec:
    id: AgentId
    role: str  # one line, shown in agent activity and to the routing model
    system_prompt: str  # trusted instructions only; never contains tool output
    task_class: TaskClass  # the gateway picks the model; no model name appears in agent code
    input_model: type[BaseModel] = AgentTask
    output_model: type[BaseModel] = AgentReply
    max_seconds: float = 30.0
    max_tokens: int = 800  # output tokens per model call
    max_tool_iterations: int = 4  # model -> tools rounds in one run
    retry: RetryPolicy = field(default_factory=RetryPolicy)
    fallback: FallbackPolicy = field(default_factory=FallbackPolicy)
    restrictions: tuple[str, ...] = ()  # hard limits, repeated to the model and enforced in code


class AgentCatalog:
    """Registered as service ``agents``."""

    def __init__(self, specs: Iterable[AgentSpec], tools: ToolRegistry) -> None:
        self._specs: dict[AgentId, AgentSpec] = {}
        for spec in specs:
            if spec.id in self._specs:
                raise ValueError(f"agent already registered: {spec.id.value}")
            self._specs[spec.id] = spec
        self._tools = tools

    def override(self, spec: AgentSpec) -> None:
        """Replace one agent's spec (deployment tuning of limits; prompts stay code-reviewed)."""
        self._specs[spec.id] = spec

    def get(self, agent: AgentId) -> AgentSpec:
        return self._specs[agent]

    def all(self) -> list[AgentSpec]:
        return [self._specs[agent] for agent in AgentId if agent in self._specs]

    def tools(self, agent: AgentId) -> list[ToolSpec]:
        """The agent's allowlist: derived from `ToolSpec.agents`, read fresh on every call."""
        return self._tools.for_agent(agent)

    def __len__(self) -> int:
        return len(self._specs)
