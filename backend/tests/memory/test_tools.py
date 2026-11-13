"""memory.remember / memory.search / memory.forget through the real executor, and the intents."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.types import AgentId, DataClass, MemoryCategory, RiskLevel
from app.memory.service import MemoryService
from app.plugins import PluginRegistry
from app.tools import Completed, Denied, Failed, NeedsApproval
from app.tools.intents import IntentContext
from tests.memory.conftest import make_ctx

NOW = datetime(2026, 11, 13, tzinfo=UTC)


async def run(registry: PluginRegistry, tool: str, args: dict[str, Any], call_id: str, **ctx: Any) -> Any:
    return await registry.service("tool_executor").execute(
        make_ctx(registry, **ctx), tool, args, call_id=call_id
    )


def test_specs_are_static_and_complete(registry: PluginRegistry) -> None:
    tools = {t.name: t for t in registry.tools}
    assert set(tools) == {"memory.remember", "memory.search", "memory.forget"}
    assert tools["memory.remember"].risk is RiskLevel.MEDIUM
    assert tools["memory.search"].risk is RiskLevel.LOW
    assert tools["memory.forget"].risk is RiskLevel.MEDIUM
    for spec in tools.values():
        assert spec.mcp_group == "memory-mcp" and spec.executor == "backend"
        assert spec.permission in ("memory.read", "memory.write") and AgentId.MEMORY in spec.agents
        assert spec.summarizer is not None and spec.card is not None
        assert not spec.untrusted_output
    assert {i.name for i in registry.intents.all()} == {"memory.remember", "memory.search", "memory.forget"}
    for intent in registry.intents.all():
        assert all(intent.keywords[lang] for lang in ("en", "hi", "hinglish"))


async def test_remember_runs_when_the_owner_asked_and_summarises_in_three_languages(
    registry: PluginRegistry, memory: MemoryService
) -> None:
    for lang, marker in [("en", "Saved"), ("hi", "सहेज"), ("hinglish", "save kar liya")]:
        out = await run(
            registry, "memory.remember", {"text": f"I prefer window seats {lang}"}, f"c_{lang}", lang=lang
        )
        assert isinstance(out, Completed), out
        assert out.result.stored and marker in (out.summary or "")  # type: ignore[attr-defined]
        assert out.card is not None and out.card.kind == "memory"
    assert len((await memory.list()).items) == 3


async def test_remember_needs_confirmation_when_not_user_initiated_or_tainted(
    registry: PluginRegistry,
) -> None:
    unasked = await run(registry, "memory.remember", {"text": "I like tea"}, "c1", user_initiated=False)
    assert isinstance(unasked, NeedsApproval)
    assert "I like tea" in unasked.request.summary  # the exact content is shown
    tainted = await run(registry, "memory.remember", {"text": "I like tea"}, "c2", tainted=True)
    assert isinstance(tainted, NeedsApproval)


async def test_remember_outcomes_for_secret_and_disabled(
    registry: PluginRegistry, memory: MemoryService
) -> None:
    secret = await run(registry, "memory.remember", {"text": "my bank pin is 4821"}, "s1")
    assert isinstance(secret, Completed) and secret.result.outcome == "rejected_secret"  # type: ignore[attr-defined]
    assert "never store passwords" in (secret.summary or "")
    bad = await run(registry, "memory.remember", {"text": ""}, "s2")
    assert isinstance(bad, Failed) and bad.error == "invalid_arguments"


async def test_search_is_read_only_ranked_and_sets_the_working_set(
    registry: PluginRegistry, memory: MemoryService, db: AsyncSession, paired_device: Any
) -> None:
    await memory.add(category=MemoryCategory.PROFILE, text="My favourite colour is blue")
    await memory.add(category=MemoryCategory.PROFILE, text="I am allergic to peanuts")
    before = (await db.execute(text("SELECT count(*), max(updated_at) FROM memory_records"))).one()
    out = await run(registry, "memory.search", {"query": "favourite colour"}, "q1", user_initiated=False)
    assert isinstance(out, Completed)
    assert out.result.count == 1 and out.result.items[0].text == "My favourite colour is blue"  # type: ignore[attr-defined]
    item = out.result.items[0]  # type: ignore[attr-defined]
    assert (item.category, item.sensitivity, item.source) == (
        MemoryCategory.PROFILE,
        DataClass.PERSONAL,
        "user",
    )
    assert out.summary == "I remember: My favourite colour is blue."
    after = (await db.execute(text("SELECT count(*), max(updated_at) FROM memory_records"))).one()
    assert tuple(before) == tuple(after)
    empty = await run(
        registry, "memory.search", {"query": "quantum chromodynamics lattice"}, "q2", lang="hinglish"
    )
    assert isinstance(empty, Completed) and empty.summary == "Is bare mein mujhe kuch yaad nahi hai."
    assert empty.card is None
    hindi = await run(registry, "memory.search", {"query": "favourite colour"}, "q3", lang="hi")
    assert isinstance(hindi, Completed) and "मुझे याद है" in (hindi.summary or "")


async def test_search_denied_without_permission(registry: PluginRegistry) -> None:
    await registry.service("permissions").set("memory.read", False)
    out = await run(registry, "memory.search", {"query": "anything"}, "d1")
    assert isinstance(out, Denied) and out.reason == "permission_not_granted:memory.read"


async def test_forget_by_id_and_by_unique_description(
    registry: PluginRegistry, memory: MemoryService
) -> None:
    a = await memory.add(category=MemoryCategory.PROFILE, text="My favourite colour is blue")
    b = await memory.add(category=MemoryCategory.PROFILE, text="I am allergic to peanuts")
    assert a.record and b.record
    by_id = await run(registry, "memory.forget", {"memory_id": a.record.id}, "f1")
    assert isinstance(by_id, Completed) and by_id.result.forgotten and "forgot" in (by_id.summary or "")  # type: ignore[attr-defined]
    by_text = await run(registry, "memory.forget", {"query": "peanut allergy"}, "f2")
    assert isinstance(by_text, Completed) and by_text.result.forgotten  # type: ignore[attr-defined]
    assert (await memory.list()).items == []
    missing = await run(registry, "memory.forget", {"memory_id": a.record.id}, "f3")
    assert isinstance(missing, Completed) and missing.result.reason == "not_found"  # type: ignore[attr-defined]
    nothing = await run(registry, "memory.forget", {"query": "quantum chromodynamics"}, "f4", lang="hi")
    assert isinstance(nothing, Completed) and nothing.result.reason == "no_match"  # type: ignore[attr-defined]


async def test_forget_with_two_matches_asks_and_resolves_the_second_one(
    registry: PluginRegistry, memory: MemoryService
) -> None:
    await memory.add(category=MemoryCategory.PROFILE, text="My brother's name is Arjun")
    await memory.add(category=MemoryCategory.PROFILE, text="My brother's birthday is in June")
    ask = await run(registry, "memory.forget", {"query": "my brother"}, "g1", conversation_id="conv_x")
    assert isinstance(ask, Completed) and ask.result.reason == "ambiguous"  # type: ignore[attr-defined]
    assert len(ask.result.candidates) == 2 and ask.card is not None  # type: ignore[attr-defined]
    assert len((await memory.list()).items) == 2  # nothing deleted yet
    # The candidates were remembered as the working set, so "the second one" resolves.
    ctx = make_ctx(registry, conversation_id="conv_x")
    shown = await ctx.working_set("memories")
    assert [s["id"] for s in shown] == [c.id for c in ask.result.candidates]  # type: ignore[attr-defined]
    spec = registry.intents.get("memory.forget")
    assert spec is not None
    slots = spec.extract(
        "forget the second one", IntentContext(lang="en", now=NOW, working_sets={"memories": shown})
    )
    assert slots == {"memory_id": shown[1]["id"]}
    done = await run(registry, "memory.forget", slots, "g2", conversation_id="conv_x")
    assert isinstance(done, Completed) and done.result.forgotten  # type: ignore[attr-defined]
    assert [r.id for r in (await memory.list()).items] == [shown[0]["id"]]


@pytest.mark.parametrize(
    ("intent", "text", "lang", "expected"),
    [
        (
            "memory.remember",
            "remember that I like my tea without sugar",
            "en",
            {"text": "I like my tea without sugar"},
        ),
        (
            "memory.remember",
            "yaad rakhna ki mera birthday 5 May hai",
            "hinglish",
            {"text": "mera birthday 5 May hai"},
        ),
        ("memory.remember", "मेरा नाम राज है याद रखना", "hi", {"text": "मेरा नाम राज है"}),
        ("memory.remember", "remember to call mom", "en", None),
        ("memory.remember", "do you remember my birthday", "en", None),
        ("memory.remember", "yaad mat rakho ki mera naam Raj hai", "hinglish", None),
        ("memory.search", "what do you remember about my diet", "en", {"query": "diet"}),
        ("memory.search", "tumhe mera birthday yaad hai?", "hinglish", {"query": "mera birthday"}),
        ("memory.search", "क्या तुम्हें मेरा जन्मदिन याद है", "hi", {"query": "मेरा जन्मदिन"}),
        ("memory.search", "remember that I like tea", "en", None),
        ("memory.forget", "forget that I like tea", "en", {"query": "I like tea"}),
        ("memory.forget", "mera birthday bhool jao", "hinglish", {"query": "mera birthday"}),
        ("memory.forget", "मेरा जन्मदिन भूल जाओ", "hi", {"query": "मेरा जन्मदिन"}),
        ("memory.forget", "delete my alarm", "en", None),
        ("memory.forget", "forget", "en", None),
    ],
)
def test_intent_slot_extraction(
    registry: PluginRegistry, intent: str, text: str, lang: str, expected: dict[str, Any] | None
) -> None:
    spec = registry.intents.get(intent)
    assert spec is not None
    assert spec.extract(text, IntentContext(lang=lang, now=NOW)) == expected


@pytest.mark.parametrize(
    ("text", "shown", "expected"),
    [
        ("forget the first one", [{"id": "m1"}, {"id": "m2"}], {"memory_id": "m1"}),
        ("doosra wala bhool jao", [{"id": "m1"}, {"id": "m2"}], {"memory_id": "m2"}),
        ("दूसरा वाला भूल जाओ", [{"id": "m1"}, {"id": "m2"}], {"memory_id": "m2"}),
        ("forget the last one", [{"id": "m1"}, {"id": "m2"}, {"id": "m3"}], {"memory_id": "m3"}),
        ("forget the third one", [{"id": "m1"}], None),
        ("forget the second one", [], None),
    ],
)
def test_forget_resolves_ordinals_against_the_working_set(
    registry: PluginRegistry, text: str, shown: list[dict[str, str]], expected: dict[str, str] | None
) -> None:
    spec = registry.intents.get("memory.forget")
    assert spec is not None
    ctx = IntentContext(lang="en", now=NOW, working_sets={"memories": shown})
    assert spec.extract(text, ctx) == expected


async def test_capabilities_are_reported_honestly(registry: PluginRegistry) -> None:
    caps = {c.id: c for c in registry.capabilities.all(domain="memory")}
    assert set(caps) == {"memory.store", "memory.embeddings", "memory.implicit_capture"}
    assert caps["memory.implicit_capture"].status.value == "unavailable"  # no gateway loaded in this registry
