"""How a registered `ToolSpec` looks to an MCP client, and how an executor outcome is returned.

The listing is derived from the registry only (name, description, input model schema, risk and
data classes as annotations); nothing here decides anything about policy.
"""

from __future__ import annotations

from typing import Any

import mcp_types as types

from app.core.types import RiskLevel
from app.tools.outcome import Completed, Denied, NeedsApproval, NeedsDeviceAction, ToolOutcome
from app.tools.spec import ToolSpec

APPROVAL_ARG = "_zoro_approval_id"
APPROVAL_META = "zoro/approval_id"

_FAILURE_ALIASES = {"call_id_conflict": "arguments_changed"}


def needs_approval(spec: ToolSpec) -> bool:
    """Every MCP call is not user-initiated, so anything above LOW waits for the owner."""
    return spec.risk is not RiskLevel.LOW


def to_mcp_tool(spec: ToolSpec) -> types.Tool:
    schema: dict[str, Any] = dict(spec.input_model.model_json_schema())
    schema["type"] = "object"
    if needs_approval(spec):
        properties = dict(schema.get("properties") or {})
        properties[APPROVAL_ARG] = {
            "type": "string",
            "description": "Only when retrying after the owner approved: the approval_id from the "
            "approval_required error. Send the same arguments as the first call.",
        }
        schema["properties"] = properties
    return types.Tool(
        name=spec.name,
        description=spec.description,
        input_schema=schema,
        output_schema=None if spec.untrusted_output else spec.output_model.model_json_schema(),
        annotations=types.ToolAnnotations(
            title=spec.description.strip().split("\n")[0][:120] or spec.name,
            read_only_hint=spec.risk is RiskLevel.LOW,
            destructive_hint=spec.risk.rank >= RiskLevel.HIGH.rank,
            open_world_hint=spec.untrusted_output,
        ),
        _meta={
            "zoro/risk": spec.risk.value,
            "zoro/data_classes": sorted(c.value for c in spec.data_classes),
            "zoro/executor": spec.executor,
            "zoro/approval": "owner_approval_required" if needs_approval(spec) else "none",
            "zoro/untrusted_output": spec.untrusted_output,
        },
    )


def error_result(code: str, message: str, **extra: Any) -> types.CallToolResult:
    body = {"error": code, "message": message, **extra}
    return types.CallToolResult(
        content=[types.TextContent(text=f"{code}: {message}")], structured_content=body, is_error=True
    )


def outcome_code(outcome: ToolOutcome) -> str:
    if isinstance(outcome, Completed):
        return "completed"
    if isinstance(outcome, NeedsApproval):
        return "approval_required"
    if isinstance(outcome, NeedsDeviceAction):
        return "device_action_pending"
    if isinstance(outcome, Denied):
        return outcome.reason
    return _FAILURE_ALIASES.get(outcome.error, outcome.error)


def to_call_result(spec: ToolSpec, outcome: ToolOutcome, *, max_result_bytes: int) -> types.CallToolResult:
    if isinstance(outcome, Completed):
        text = outcome.model_text  # already wrapped in <untrusted> when the tool's output is
        size = len(text.encode("utf-8"))
        if size > max_result_bytes:
            return error_result(
                "result_too_large",
                f"The result is {size} bytes; this gateway returns at most {max_result_bytes}.",
            )
        meta = {
            "zoro/call_id": outcome.call_id,
            "zoro/untrusted": outcome.untrusted,
            "zoro/data_classes": sorted(c.value for c in outcome.data_classes),
            "zoro/summary": outcome.summary,
        }
        return types.CallToolResult(
            content=[types.TextContent(text=text)],
            structured_content=None if outcome.untrusted else outcome.result.model_dump(mode="json"),
            is_error=False,
            _meta=meta,
        )
    if isinstance(outcome, NeedsApproval):
        request = outcome.request
        return error_result(
            "approval_required",
            f"The owner must approve '{request.title}' in the ZORO app (Approvals). After they "
            f"approve, call {spec.name} again with the same arguments plus "
            f'"{APPROVAL_ARG}": "{request.approval_id}".',
            approval_id=request.approval_id,
            level=request.level.value,
            expires_at=request.expires_at.isoformat(),
            retry_argument=APPROVAL_ARG,
            retry_meta_key=APPROVAL_META,
        )
    if isinstance(outcome, NeedsDeviceAction):
        return error_result("device_action_pending", "The device has not answered yet.", retryable=True)
    if isinstance(outcome, Denied):
        return error_result(outcome.reason, outcome.message or "The policy engine refused this call.")
    return error_result(
        outcome_code(outcome), outcome.message or "The call could not complete.", retryable=outcome.retryable
    )
