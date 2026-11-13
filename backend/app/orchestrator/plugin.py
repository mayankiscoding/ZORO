"""Registers the supervisor, the turn service and the turn / conversation routes."""

from __future__ import annotations

from typing import Any

from app.core.types import CapabilityStatus
from app.orchestrator.checkpoint import CheckpointerHandle
from app.orchestrator.service import TurnService
from app.orchestrator.store import ConversationStore
from app.orchestrator.supervisor import Supervisor
from app.schemas.security import Capability


def register(reg: Any) -> None:
    if not reg.has_service("agents"):  # the supervisor needs the agent catalog and runner
        from app.agents.plugin import register as register_agents

        register_agents(reg)

    from app.orchestrator.api import build_router

    settings = reg.service("settings")
    store = ConversationStore(reg.service("session_factory"), reg.service("cipher"), reg.service("clock"))
    checkpoints = CheckpointerHandle(settings)
    supervisor = Supervisor(reg)
    service = TurnService(reg, supervisor, store, checkpoints)

    reg.provide("conversations", store)
    reg.provide("checkpoints", checkpoints)
    reg.provide("supervisor", supervisor)
    reg.provide("turn_service", service)
    reg.add_router(build_router(service, store))
    if reg.has_service("approval_router"):  # one route answers any approval; a turn is one owner
        reg.service("approval_router").register("turn", service.owns_approval, service.decide_approval)
    reg.add_startup(service.startup)
    reg.add_shutdown(service.shutdown)

    notes = {
        "memory": "Suspended turns are kept in memory and are lost when the server restarts.",
        "sqlite": "Suspended turns are checkpointed (encrypted) in a SQLite file and survive a restart.",
        "postgres": "Suspended turns are checkpointed (encrypted) in PostgreSQL and survive a restart.",
    }
    reg.add_capability(
        Capability(
            id="orchestrator.turns",
            title="Conversation turns with approvals and device actions",
            domain="orchestrator",
            status=CapabilityStatus.WORKING_LOCAL,
            note=notes[checkpoints.kind],
        )
    )
