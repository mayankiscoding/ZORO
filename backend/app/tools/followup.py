"""Follow-ups: the one way a tool hands the next step of a multi-step plan to the orchestrator.

A tool's output model declares ``follow_ups: list[FollowUp]``. The executor copies them onto
`Completed.follow_ups`; the orchestrator queues each one as an ordinary call and runs it through
`ToolExecutor` like any other: allowlist, argument validation, policy, approvals, device dispatch,
rate limits and budgets all apply. A follow-up therefore never bypasses policy: it runs as the
agent of the call that produced it, and it inherits the turn's taint.

The list is a chain. Step 0 may take arguments from the result of the tool that returned the
chain; step N from the result of step N-1 (`args_from_previous`: argument name -> dotted path in
that result). When a step does not complete, the steps after it are skipped, not run.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.core.types import DevicePlatform

MAX_FOLLOW_UPS = 6  # per result
MAX_FOLLOW_UP_DEPTH = 4  # a follow-up of a follow-up of ...
_MISSING = object()


class FollowUp(BaseModel):
    """One next step: a registered tool, its arguments, and where a device tool should run."""

    model_config = ConfigDict(extra="ignore")

    tool: str
    args: dict[str, Any] = Field(default_factory=dict)
    # argument name -> dotted path into the previous step's result ("hits", "draft.address")
    args_from_previous: dict[str, str] = Field(default_factory=dict)
    target_device_id: str | None = None  # an explicit paired device
    target_platform: DevicePlatform | None = None  # "on my Mac" / "on my iPhone"


def follow_ups_of(result: BaseModel) -> tuple[FollowUp, ...]:
    """The follow-ups a tool result carries (its ``follow_ups`` field), bounded and validated."""
    raw = getattr(result, "follow_ups", None)
    if not isinstance(raw, list | tuple):
        return ()
    found: list[FollowUp] = []
    for item in raw[:MAX_FOLLOW_UPS]:
        if isinstance(item, FollowUp):
            found.append(item)
        elif isinstance(item, BaseModel | dict):
            data = item.model_dump(mode="json") if isinstance(item, BaseModel) else item
            try:
                found.append(FollowUp.model_validate(data))
            except ValueError:
                continue
    return tuple(found)


def dig(data: Any, path: str) -> Any:
    """Value at a dotted path in JSON data; raises `KeyError` when any part is absent."""
    current = data
    for part in path.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and part.isdigit() and int(part) < len(current):
            current = current[int(part)]
        else:
            raise KeyError(path)
    return current


def resolve_args(
    args: dict[str, Any], args_from_previous: dict[str, str], previous_result: Any
) -> dict[str, Any]:
    """Static arguments plus the ones taken from the previous step's result. A path that is not
    in the result raises `KeyError` (the step is then skipped, never run with a guess)."""
    resolved = dict(args)
    for name, path in args_from_previous.items():
        resolved[name] = dig(previous_result, path)
    return resolved


def external_model_allowed(result: BaseModel) -> bool:
    """False when a tool result says it must not be shown to an external model (for example data
    from a source whose terms forbid AI use). Read from the result's ``external_model_allowed``."""
    return getattr(result, "external_model_allowed", True) is not False
