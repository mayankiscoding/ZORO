"""Turning tool data into what is shown: approval views, completed outcomes, journal encoding."""

from __future__ import annotations

import logging
from typing import Any

from pydantic import BaseModel, ValidationError

from app.core.ids import canonical_json
from app.schemas.common import LabelValue, UICard
from app.security.taint import wrap_untrusted
from app.tools.followup import external_model_allowed, follow_ups_of
from app.tools.outcome import Completed, Denied, Failed, ToolOutcome
from app.tools.spec import ApprovalView, ToolContext, ToolSpec

log = logging.getLogger(__name__)

_MAX_VALUE = 4000


def _show(value: Any) -> str:
    text = value if isinstance(value, str) else canonical_json(value)
    return text if len(text) <= _MAX_VALUE else text[:_MAX_VALUE] + "…"


def default_approval_view(tool: ToolSpec, args_json: dict[str, Any]) -> ApprovalView:
    """Every argument, exactly as it will be executed (recipient and content included)."""
    details = tuple(LabelValue(label=key, value=_show(value)) for key, value in args_json.items())
    title = tool.description.strip().split("\n")[0].rstrip(".")[:120] or tool.name
    summary = "\n".join(f"{item.label}: {item.value}" for item in details) or tool.name
    return ApprovalView(title=title, summary=summary, details=details)


def resolve_approval_view(tool: ToolSpec, args: BaseModel, args_json: dict[str, Any]) -> ApprovalView:
    """The tool's own view when it provides one and it works; otherwise the full argument list."""
    if tool.approval_view is not None:
        try:
            view = tool.approval_view(args)
            if isinstance(view, ApprovalView) and view.title and view.summary:
                return view
        except Exception as exc:
            log.error("approval_view failed", extra={"tool": tool.name, "error_type": type(exc).__name__})
    return default_approval_view(tool, args_json)


def build_completed(
    ctx: ToolContext, tool: ToolSpec, result: BaseModel, call_id: str, duration_ms: int
) -> Completed:
    """Wrap untrusted output and mark the turn tainted; attach the spoken summary and the card."""
    text = result.model_dump_json()
    if tool.untrusted_output:
        ctx.mark_tainted()
        text = wrap_untrusted(text, source=tool.name)
    summary: str | None = None
    card: UICard | None = None
    if tool.summarizer is not None:
        try:
            summary = tool.summarizer(result, ctx.lang)
        except Exception as exc:
            log.error("summarizer failed", extra={"tool": tool.name, "error_type": type(exc).__name__})
    if tool.card is not None:
        try:
            card = tool.card(result)
        except Exception as exc:
            log.error("card builder failed", extra={"tool": tool.name, "error_type": type(exc).__name__})
    return Completed(
        result,
        call_id=call_id,
        tool=tool.name,
        data_classes=tool.data_classes,
        untrusted=tool.untrusted_output,
        model_text=text,
        summary=summary,
        card=card,
        duration_ms=duration_ms,
        follow_ups=follow_ups_of(result),
        external_model_allowed=external_model_allowed(result),
    )


def encode_outcome(outcome: ToolOutcome) -> dict[str, Any]:
    """JSON form of a final outcome for the journal (suspensions are not final)."""
    if isinstance(outcome, Completed):
        return {
            "kind": "completed",
            "result": outcome.result.model_dump(mode="json"),
            "duration_ms": outcome.duration_ms,
        }
    if isinstance(outcome, Denied):
        return {"kind": "denied", "reason": outcome.reason, "message": outcome.message}
    if isinstance(outcome, Failed):
        return {
            "kind": "failed",
            "error": outcome.error,
            "message": outcome.message,
            "retryable": outcome.retryable,
        }
    raise TypeError("only final outcomes are journaled")


def decode_outcome(ctx: ToolContext, tool: ToolSpec, stored: dict[str, Any], call_id: str) -> ToolOutcome:
    kind = stored.get("kind")
    if kind == "completed":
        try:
            result = tool.output_model.model_validate(stored.get("result"))
        except ValidationError:
            return Failed("invalid_result", call_id=call_id, tool=tool.name)
        return build_completed(ctx, tool, result, call_id, int(stored.get("duration_ms", 0)))
    if kind == "denied":
        return Denied(
            str(stored.get("reason", "denied")), call_id=call_id, tool=tool.name,
            message=str(stored.get("message", "")),
        )  # fmt: skip
    return Failed(
        str(stored.get("error", "tool_error")),
        call_id=call_id,
        tool=tool.name,
        message=str(stored.get("message", "")),
        retryable=bool(stored.get("retryable", False)),
    )
