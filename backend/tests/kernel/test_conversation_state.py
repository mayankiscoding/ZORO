from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import FixedClock
from app.core.types import AgentId
from app.plugins import PluginRegistry
from app.tools.state import ConversationStateStore, ConversationStateTooLarge


def _store(registry: PluginRegistry) -> ConversationStateStore:
    store: ConversationStateStore = registry.service("conversation_state")
    return store


async def test_working_set_round_trip_keeps_order(registry: PluginRegistry) -> None:
    store = _store(registry)
    items = [{"ref": "p1", "label": "first"}, {"ref": "p2", "label": "second"}]
    await store.set_working_set("conv_1", "products", items)

    assert await store.working_set("conv_1", "products") == items
    assert await store.working_sets("conv_1") == {"products": items}
    assert await store.working_set("conv_2", "products") == []
    assert await store.working_set("conv_1", "contacts") == []


async def test_state_expires_and_is_purged(registry: PluginRegistry, clock: FixedClock) -> None:
    store = _store(registry)
    await store.set_working_set("conv_1", "products", [{"ref": "p1"}], ttl_s=60)
    clock.advance(61)

    assert await store.working_set("conv_1", "products") == []
    assert await store.working_sets("conv_1") == {}
    assert await store.purge_expired() == 1


async def test_values_are_sealed_at_rest(registry: PluginRegistry, db: AsyncSession) -> None:
    store = _store(registry)
    await store.put("conv_1", "note", {"phone": "9999912345", "name": "नमस्ते"})

    raw = (await db.execute(text("select value_enc from kernel_conversation_state"))).scalar_one()
    assert "9999912345" not in raw
    assert await store.get("conv_1", "note") == {"phone": "9999912345", "name": "नमस्ते"}


async def test_delete_one_key_or_whole_conversation(registry: PluginRegistry) -> None:
    store = _store(registry)
    await store.put("conv_1", "a", 1)
    await store.put("conv_1", "b", 2)
    await store.delete("conv_1", "a")
    assert await store.get("conv_1", "a") is None
    assert await store.get("conv_1", "b") == 2
    await store.delete("conv_1")
    assert await store.get("conv_1", "b") is None


async def test_oversized_value_is_refused(registry: PluginRegistry) -> None:
    store = _store(registry)
    try:
        await store.put("conv_1", "big", "x" * (70 * 1024))
    except ConversationStateTooLarge:
        pass
    else:
        raise AssertionError("expected ConversationStateTooLarge")


async def test_tool_context_helpers(registry: PluginRegistry) -> None:
    ctx = registry.tool_context(turn_id="turn_1", agent=AgentId.SHOPPING, conversation_id="conv_9")
    await ctx.set_working_set("products", [{"ref": "x"}])
    assert await ctx.working_set("products") == [{"ref": "x"}]

    without_conversation = registry.tool_context(turn_id="turn_2", agent=AgentId.SHOPPING)
    await without_conversation.set_working_set("products", [{"ref": "y"}])
    assert await without_conversation.working_set("products") == []
