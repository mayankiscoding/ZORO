"""Registers the agent catalog, the runner and the security agent's read-only tools."""

from __future__ import annotations

from typing import Any

from app.agents.catalog import default_specs
from app.agents.runner import AgentRunner
from app.agents.security import build_security_tools
from app.agents.spec import AgentCatalog
from app.core.types import CapabilityStatus
from app.schemas.security import Capability


def register(reg: Any) -> None:
    if reg.has_service("agents"):  # the orchestrator plugin may have registered us already
        return
    catalog = AgentCatalog(default_specs(), reg.tools)
    reg.provide("agents", catalog)
    reg.provide("agent_runner", AgentRunner(reg, catalog))

    tools, intents = build_security_tools(reg)
    for tool in tools:
        reg.add_tool(tool)
    for intent in intents:
        reg.add_intent(intent)

    def capabilities() -> list[Capability]:
        has_gateway = reg.has_service("gateway")
        return [
            Capability(
                id="agents.deterministic",
                title="Known requests answered without a model",
                domain="agents",
                status=CapabilityStatus.WORKING_LOCAL,
                note=f"{len(reg.intents)} registered intents are routed and answered by plain code.",
            ),
            Capability(
                id="agents.model_reasoning",
                title="Open-ended requests answered with a model",
                domain="agents",
                status=CapabilityStatus.WORKING_LOCAL if has_gateway else CapabilityStatus.UNAVAILABLE,
                note=(
                    "Used only when the privacy mode allows the data to reach a configured model; "
                    "see the models.* capabilities for which providers have credentials."
                    if has_gateway
                    else "No model gateway is loaded; ZORO answers known requests only."
                ),
            ),
        ]

    reg.add_capability(capabilities)
