"""Registers the documents package. Works without the memory plugin (the knowledge category is then
always on) and without a gateway (local embedder)."""

from __future__ import annotations

from typing import Any

from app.core.types import CapabilityStatus, IntegrationLevel, MemoryCategory
from app.documents.api import router
from app.documents.service import DocumentService
from app.documents.tools import build_tools
from app.schemas.security import Capability


def _pdf_capability() -> Capability:
    try:
        import pdfplumber  # noqa: F401
    except ImportError:
        return Capability(
            id="documents.pdf_text",
            title="PDF text extraction",
            domain="documents",
            status=CapabilityStatus.UNAVAILABLE,
            integration_level=IntegrationLevel.UNAVAILABLE,
            requires=["pdfplumber"],
            note="The pdfplumber package is not installed.",
        )
    return Capability(
        id="documents.pdf_text",
        title="PDF text extraction",
        domain="documents",
        status=CapabilityStatus.WORKING_LOCAL,
        integration_level=IntegrationLevel.FULLY_INTEGRATED,
        note="Text-based PDFs only; scanned or image-only PDFs need OCR, which is not available.",
    )


def register(reg: Any) -> None:
    def optional(name: str) -> Any | None:
        return reg.service(name) if reg.has_service(name) else None

    service = DocumentService(
        reg.service("session_factory"),
        reg.service("cipher"),
        reg.service("clock"),
        reg.service("objects"),
        memory=lambda: optional("memory"),
        gateway=lambda: optional("gateway"),
        privacy=lambda: optional("privacy_state"),
        audit=reg.service("audit"),
    )
    reg.provide("documents", service)

    reg.add_permission("documents.read", "Let ZORO search and list your documents", True)
    reg.add_permission("storage.read", "Let ZORO list stored files (names and sizes only)", True)
    for spec in build_tools(service):
        reg.add_tool(spec)
    reg.add_router(router)

    memory = optional("memory")
    if memory is not None:  # the knowledge category owns documents: delete and export reach them
        memory.add_purger(MemoryCategory.KNOWLEDGE, service.purge_all)
        memory.add_exporter(MemoryCategory.KNOWLEDGE, service.export_rows)

    reg.add_capability(_pdf_capability)
    reg.add_capability(
        Capability(
            id="documents.ingest",
            title="Document upload and private search",
            domain="documents",
            status=CapabilityStatus.WORKING_LOCAL,
            integration_level=IntegrationLevel.FULLY_INTEGRATED,
            note="PDF, TXT, MD and CSV up to 15 MB, stored on your server and searched with local embeddings.",
        )
    )
