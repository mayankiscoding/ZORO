"""Apply `app.security.redaction` to every message the gateway sends (content and tool-call arguments)."""

from __future__ import annotations

from typing import Any

from app.providers.types import ChatMessage, ToolCall
from app.security.redaction import redact_text


def redact_value(value: Any) -> Any:
    if isinstance(value, str):
        return redact_text(value).text
    if isinstance(value, dict):
        return {k: redact_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_value(v) for v in value]
    return value


def redact_messages(messages: tuple[ChatMessage, ...]) -> tuple[ChatMessage, ...]:
    out = []
    for m in messages:
        calls = tuple(
            ToolCall(id=c.id, name=c.name, arguments=redact_value(c.arguments), signature=c.signature)
            for c in m.tool_calls
        )
        out.append(m.model_copy(update={"content": redact_text(m.content).text, "tool_calls": calls}))
    return tuple(out)
