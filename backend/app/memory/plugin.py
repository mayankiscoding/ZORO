"""Registers the memory package: service, tools, intents, router, capabilities, permissions, sweeper."""

from __future__ import annotations

from typing import Any

from app.core.types import CapabilityStatus, IntegrationLevel
from app.memory.admin import MemoryAdmin, RetentionSweeper
from app.memory.api import router
from app.memory.intents import build_intents
from app.memory.prefs import MemoryPrefs
from app.memory.service import MemoryService
from app.memory.tools import build_tools
from app.schemas.security import Capability


def register(reg: Any) -> None:
    settings = reg.service("settings")

    def optional(name: str) -> Any | None:
        return reg.service(name) if reg.has_service(name) else None

    service = MemoryService(
        reg.service("session_factory"),
        reg.service("cipher"),
        reg.service("clock"),
        prefs=MemoryPrefs(reg.service("session_factory"), settings.conversation_retention_days),
        audit=reg.service("audit"),
        gateway=lambda: optional("gateway"),
        privacy=lambda: optional("privacy_state"),
    )
    admin = MemoryAdmin(
        service, proofs=reg.service("proofs"), conversation_state=lambda: optional("conversation_state")
    )
    sweeper = RetentionSweeper(admin)
    reg.provide("memory", service)
    reg.provide("memory_admin", admin)

    reg.add_permission("memory.read", "Let ZORO recall what it remembers about you", True)
    reg.add_permission("memory.write", "Let ZORO save and forget memories when you ask", True)
    for spec in build_tools(service):
        reg.add_tool(spec)
    for intent in build_intents():
        reg.add_intent(intent)
    reg.add_router(router)

    reg.add_capability(
        Capability(
            id="memory.store",
            title="Long-term memory (seven categories)",
            domain="memory",
            status=CapabilityStatus.WORKING_LOCAL,
            integration_level=IntegrationLevel.FULLY_INTEGRATED,
            note="Stored on your server. Text above personal sensitivity is encrypted at rest; "
            "each category can be switched off, limited in time, exported or deleted.",
        )
    )
    reg.add_capability(
        Capability(
            id="memory.embeddings",
            title="Memory search embeddings",
            domain="memory",
            status=CapabilityStatus.WORKING_LOCAL,
            integration_level=IntegrationLevel.FULLY_INTEGRATED,
            note="Offline hashing embedder always available; a cloud embedding model is used only when "
            "the privacy policy permits the record's data classes.",
        )
    )

    def implicit_capture() -> Capability:
        have_gateway = reg.has_service("gateway")
        return Capability(
            id="memory.implicit_capture",
            title="Learning facts from conversation",
            domain="memory",
            status=CapabilityStatus.WORKING_LOCAL if have_gateway else CapabilityStatus.UNAVAILABLE,
            integration_level=IntegrationLevel.FULLY_INTEGRATED
            if have_gateway
            else IntegrationLevel.UNAVAILABLE,
            note="Needs a model the privacy policy permits; sensitive facts wait for your review. "
            "Explicit 'remember ...' requests always work."
            if have_gateway
            else "No model gateway is loaded; only explicit 'remember ...' requests are stored.",
        )

    reg.add_capability(implicit_capture)
    reg.add_startup(sweeper.start)
    reg.add_shutdown(sweeper.stop)
