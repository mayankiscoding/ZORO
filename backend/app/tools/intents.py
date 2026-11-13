"""How a package teaches the local router its intents (no model needed)."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from app.core.types import AgentId, DevicePlatform

LANGUAGES: tuple[str, ...] = ("en", "hi", "hinglish")


@dataclass(frozen=True)
class IntentContext:
    """What slot filling may look at besides the utterance."""

    lang: str  # "en" | "hi" | "hinglish"
    now: datetime  # timezone-aware
    timezone: str = "Asia/Kolkata"
    platform: DevicePlatform | None = None
    capabilities: tuple[str, ...] = ()  # device tool names the requesting device can run
    app_state: Mapping[str, Any] = field(default_factory=dict)  # e.g. {"selected_product_ref": "..."}
    last_agent: AgentId | None = None  # the agent that answered the previous turn (follow-ups)
    conversation_id: str | None = None
    # kind -> items last shown in this conversation, in display order (from ConversationStateStore),
    # so slot filling can resolve "the second one" / "doosra wala" / "दूसरा वाला".
    working_sets: Mapping[str, Sequence[Mapping[str, Any]]] = field(default_factory=dict)


@dataclass(frozen=True)
class IntentSpec:
    name: str  # "<package>.<intent>", unique
    agent: AgentId
    tool: str  # the tool the extracted slots are arguments for
    keywords: Mapping[str, Sequence[str]]  # {"en": […], "hi": […], "hinglish": […]}
    extract: Callable[[str, IntentContext], dict[str, Any] | None]  # slot filling; None = not this intent
    examples: Sequence[str] = ()
    priority: int = 0


class IntentRegistry:
    def __init__(self) -> None:
        self._intents: dict[str, IntentSpec] = {}

    def register(self, spec: IntentSpec) -> IntentSpec:
        if not spec.name:
            raise ValueError("intent needs a name")
        if spec.name in self._intents:
            raise ValueError(f"intent already registered: {spec.name}")
        unknown = set(spec.keywords) - set(LANGUAGES)
        if unknown:
            raise ValueError(f"{spec.name}: unknown keyword languages {sorted(unknown)}")
        self._intents[spec.name] = spec
        return spec

    def get(self, name: str) -> IntentSpec | None:
        return self._intents.get(name)

    def all(self) -> list[IntentSpec]:
        """Highest priority first, then by name (stable for deterministic routing)."""
        return sorted(self._intents.values(), key=lambda spec: (-spec.priority, spec.name))

    def for_agent(self, agent: AgentId) -> list[IntentSpec]:
        return [spec for spec in self.all() if spec.agent == agent]

    def __len__(self) -> int:
        return len(self._intents)
