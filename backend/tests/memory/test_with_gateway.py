"""Memory and documents next to the real model gateway: with no permitted model the local embedder is used."""

from __future__ import annotations

from collections.abc import Sequence

import httpx
import pytest

from app.core.types import MemoryCategory
from app.documents.service import DocumentService
from app.memory.service import MemoryService
from app.plugins import PluginRegistry
from tests.conftest import PairedDevice
from tests.memory.conftest import make_ctx


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.providers.plugin", "app.memory.plugin", "app.documents.plugin")


async def test_memory_and_documents_work_with_the_real_gateway(registry: PluginRegistry) -> None:
    assert registry.has_service("gateway")
    memory: MemoryService = registry.service("memory")
    documents: DocumentService = registry.service("documents")
    await memory.add(category=MemoryCategory.PROFILE, text="My favourite colour is blue")
    ctx = make_ctx(registry)
    assert ctx.gateway is not None
    assert (await memory.recall("favourite colour", ctx=ctx))[0].text == "My favourite colour is blue"
    await documents.upload("note.txt", b"The warranty on the washing machine lasts three years.")
    assert (await documents.search("washing machine warranty", gateway=ctx.gateway))[0].title == "note.txt"
    # Implicit capture finds no permitted model in strict private mode with no local model: nothing is stored.
    assert await memory.propose_from_turn("I always drink coffee after lunch", "Noted.", ctx) == []


async def test_capabilities_endpoint_lists_memory_and_documents(
    client: httpx.AsyncClient, paired_device: PairedDevice
) -> None:
    body = (await client.get("/v1/capabilities", headers=paired_device.headers)).json()
    items = body["items"] if isinstance(body, dict) else body
    by_id = {c["id"]: c for c in items}
    assert by_id["memory.store"]["status"] == "working_local"
    assert by_id["memory.implicit_capture"]["status"] == "working_local"
    assert by_id["documents.pdf_text"]["status"] == "working_local"
