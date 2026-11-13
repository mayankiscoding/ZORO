"""Routes run tools through the kernel `ToolExecutor`, so HTTP calls get the same policy, audit and
approval rules as a voice turn. No business logic here."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel

from app.core.errors import Forbidden, Unavailable, ZoroError
from app.core.ids import new_id
from app.core.types import AgentId
from app.schemas.turns import ApprovalRequest
from app.tools.outcome import Completed, Denied, Failed, NeedsApproval


class ToolFailed(ZoroError):
    code = "tool_failed"
    status = 400
    default_message = "The action could not be completed."


class ToolRun(BaseModel):
    status: str  # completed | needs_approval
    result: dict[str, Any] | None = None
    approval: ApprovalRequest | None = None


async def run_tool(
    reg: Any,
    device_id: str,
    tool: str,
    args: BaseModel | dict[str, Any],
    *,
    agent: AgentId,
    lang: str = "en",
    conversation_id: str | None = None,
) -> ToolRun:
    ctx = reg.tool_context(
        turn_id=new_id("http"),
        agent=agent,
        device_id=device_id,
        lang=lang,
        user_initiated=True,
        conversation_id=conversation_id,
    )
    raw = args.model_dump(mode="json") if isinstance(args, BaseModel) else args
    outcome = await reg.service("tool_executor").execute(ctx, tool, raw, call_id=new_id("call"))
    if isinstance(outcome, Completed):
        return ToolRun(status="completed", result=outcome.result.model_dump(mode="json"))
    if isinstance(outcome, NeedsApproval):
        return ToolRun(status="needs_approval", approval=outcome.request)
    if isinstance(outcome, Denied):
        raise Forbidden(outcome.message or "Not allowed.", code=outcome.reason)
    if isinstance(outcome, Failed):
        if outcome.retryable:
            raise Unavailable(outcome.message or None, code=outcome.error)
        raise ToolFailed(outcome.message or None, code=outcome.error)
    raise ToolFailed("Unexpected outcome.")
