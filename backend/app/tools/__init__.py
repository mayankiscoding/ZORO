"""Tool kernel: specs, registry, executor, intents, device dispatch."""

from app.tools.dispatcher import DeviceDispatcher, DeviceNoAnswer, DeviceOffline, NullDeviceDispatcher
from app.tools.executor import ToolExecutor
from app.tools.followup import FollowUp
from app.tools.intents import IntentContext, IntentRegistry, IntentSpec
from app.tools.outcome import Completed, Denied, Failed, NeedsApproval, NeedsDeviceAction, ToolOutcome
from app.tools.ratelimit import TokenBucketRateLimiter
from app.tools.registry import ToolRegistrationError, ToolRegistry
from app.tools.spec import ApprovalView, ToolContext, ToolHandler, ToolSpec

__all__ = [
    "ApprovalView",
    "Completed",
    "Denied",
    "DeviceDispatcher",
    "DeviceNoAnswer",
    "DeviceOffline",
    "Failed",
    "FollowUp",
    "IntentContext",
    "IntentRegistry",
    "IntentSpec",
    "NeedsApproval",
    "NeedsDeviceAction",
    "NullDeviceDispatcher",
    "TokenBucketRateLimiter",
    "ToolContext",
    "ToolExecutor",
    "ToolHandler",
    "ToolOutcome",
    "ToolRegistrationError",
    "ToolRegistry",
    "ToolSpec",
]
