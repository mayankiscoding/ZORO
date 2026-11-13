"""Context-window trimming with a conservative token estimate.

Never drops a system message or the latest user message (nor anything after it: the current tool
loop). Older turns go first, oldest first; an assistant tool-call message and its tool results are
dropped together so no tool result is left without its call.
"""

from __future__ import annotations

import json
import math

from app.providers.types import ChatMessage, ProviderError, ToolDef

_PER_MESSAGE = 4


class ContextOverflow(ProviderError):
    def __init__(self, needed: int, budget: int) -> None:
        super().__init__("bad_request", f"context_overflow needed={needed} budget={budget}")
        self.needed = needed
        self.budget = budget


def estimate_tokens(text: str) -> int:
    """Over-estimate: one token per 3 UTF-8 bytes (English is ~4, Devanagari is 3 bytes per char)."""
    return math.ceil(len(text.encode("utf-8")) / 3)


def message_tokens(m: ChatMessage) -> int:
    n = _PER_MESSAGE + estimate_tokens(m.content)
    for tc in m.tool_calls:
        n += estimate_tokens(tc.name) + estimate_tokens(json.dumps(tc.arguments, ensure_ascii=False))
    return n


def tools_tokens(tools: tuple[ToolDef, ...]) -> int:
    return sum(
        estimate_tokens(t.name + t.description + json.dumps(t.parameters, ensure_ascii=False)) for t in tools
    )


def _units(messages: tuple[ChatMessage, ...]) -> list[list[int]]:
    """Group indexes: an assistant message with tool calls absorbs the tool messages that follow it."""
    units: list[list[int]] = []
    for i, m in enumerate(messages):
        if m.role == "tool" and units and messages[units[-1][0]].tool_calls:
            units[-1].append(i)
        else:
            units.append([i])
    return units


def trim_messages(messages: tuple[ChatMessage, ...], budget: int) -> tuple[ChatMessage, ...]:
    total = sum(message_tokens(m) for m in messages)
    if total <= budget:
        return messages
    last_user = max((i for i, m in enumerate(messages) if m.role == "user"), default=len(messages))
    droppable = [u for u in _units(messages) if u[0] < last_user and messages[u[0]].role != "system"]
    dropped: set[int] = set()
    for unit in droppable:
        if total <= budget:
            break
        dropped.update(unit)
        total -= sum(message_tokens(messages[i]) for i in unit)
    if total > budget:
        raise ContextOverflow(total, budget)
    return tuple(m for i, m in enumerate(messages) if i not in dropped)


def input_budget(context_window: int, max_output_tokens: int, tools: tuple[ToolDef, ...]) -> int:
    margin = max(256, context_window // 50)
    return context_window - max_output_tokens - tools_tokens(tools) - margin
