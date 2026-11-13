"""MemoryService: retrieval, merge, deletion, disabled categories, sensitivity, retention, review."""

from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import FixedClock
from app.core.errors import Forbidden, NotFound
from app.core.types import DataClass, MemoryCategory, PrivacyMode
from app.memory.admin import MemoryAdmin
from app.memory.service import MemoryService
from app.plugins import PluginRegistry
from app.schemas.data import MemoryCategorySetting, MemoryPatch, MemorySettings
from tests.fakes.gateway import FakeGateway
from tests.memory.conftest import make_ctx

P = MemoryCategory.PROFILE


async def raw_count(db: AsyncSession) -> int:
    return int((await db.execute(text("SELECT count(*) FROM memory_records"))).scalar_one())


async def seed(memory: MemoryService) -> dict[str, str]:
    ids: dict[str, str] = {}
    for key, cat, body in [
        ("colour", P, "My favourite colour is blue"),
        ("peanuts", P, "I am allergic to peanuts"),
        ("birthday", P, "Mom's birthday is on 5 May"),
        ("flight", MemoryCategory.EPISODIC, "Flew to Pune for the conference last March"),
        ("fact", MemoryCategory.KNOWLEDGE, "The wifi router is in the hallway cupboard"),
    ]:
        result = await memory.add(category=cat, text=body, source=f"seed:{key}")
        assert result.record is not None
        ids[key] = result.record.id
    return ids


async def test_relevant_record_ranks_first_with_local_embedder(
    registry: PluginRegistry, memory: MemoryService
) -> None:
    ids = await seed(memory)
    ctx = make_ctx(registry)
    for query, expected in [
        ("what is my favourite colour", "colour"),
        ("peanut allergy", "peanuts"),
        ("when is mom's birthday", "birthday"),
        ("where is the wifi router", "fact"),
    ]:
        items = await memory.recall(query, limit=3, ctx=ctx)
        assert items, query
        assert items[0].id == ids[expected], (query, [i.text for i in items])


async def test_hinglish_keyword_retrieval(registry: PluginRegistry, memory: MemoryService) -> None:
    await memory.add(category=P, text="mera birthday 5 May hai")
    await memory.add(category=P, text="I like cycling on Sundays")
    items = await memory.recall("mera birthday kab hai", ctx=make_ctx(registry))
    assert items and "birthday" in items[0].text


async def test_unrelated_query_recalls_nothing(registry: PluginRegistry, memory: MemoryService) -> None:
    await seed(memory)
    assert await memory.recall("quantum chromodynamics lattice", ctx=make_ctx(registry)) == []


async def test_recall_items_carry_provenance(registry: PluginRegistry, memory: MemoryService) -> None:
    await memory.add(
        category=P, text="My favourite colour is blue", source="conversation:conv_9", confidence=0.8
    )
    [item] = await memory.recall("favourite colour", ctx=make_ctx(registry))
    assert item.category is P
    assert item.sensitivity is DataClass.PERSONAL
    assert item.confidence == pytest.approx(0.8)
    assert item.source == "conversation:conv_9"
    assert 0 < item.score <= 1


async def test_near_duplicate_is_merged_not_duplicated(memory: MemoryService, db: AsyncSession) -> None:
    first = await memory.add(category=P, text="My favourite colour is blue", confidence=0.7)
    again = await memory.add(category=P, text="my favourite colour is blue.", confidence=0.9)
    assert first.outcome == "created" and again.outcome == "merged"
    assert again.record is not None and first.record is not None and again.record.id == first.record.id
    assert again.record.confidence == pytest.approx(0.9)
    assert await raw_count(db) == 1


async def test_owner_edit_is_never_silently_overwritten(memory: MemoryService) -> None:
    created = await memory.add(category=P, text="I like tea")
    assert created.record is not None
    await memory.patch(created.record.id, MemoryPatch(text="I like tea with milk"))
    # A later near-duplicate of the edited text, even a newer or more confident one, must not touch it.
    again = await memory.add(category=P, text="I like tea with milk!", confidence=1.0)
    assert again.outcome == "kept_existing"
    assert (await memory.get(created.record.id)).text == "I like tea with milk"


async def test_correction_keeps_provenance_and_verifies(memory: MemoryService, clock: FixedClock) -> None:
    created = await memory.add(
        category=P, text="My doctor is Dr Rao", source="conversation:conv_3", confidence=0.7
    )
    assert created.record is not None
    clock.advance(3600)
    fixed = await memory.patch(created.record.id, MemoryPatch(text="My doctor is Dr Rai"))
    assert fixed.id == created.record.id
    assert fixed.source == "conversation:conv_3"
    assert fixed.created_at == created.record.created_at
    assert fixed.text == "My doctor is Dr Rai"
    assert fixed.confidence == 1.0
    assert fixed.last_verified_at == clock.now()
    assert fixed.sensitivity is DataClass.HEALTH  # raised by the text itself, never lowered
    await_row = await memory.get(created.record.id)
    assert await_row.sensitivity is DataClass.HEALTH


async def test_verify_stamps_last_verified_at(memory: MemoryService, clock: FixedClock) -> None:
    created = await memory.add(category=P, text="I live in Pune")
    assert created.record is not None and created.record.last_verified_at is None
    clock.advance(60)
    verified = await memory.patch(created.record.id, MemoryPatch(verified=True))
    assert verified.last_verified_at == clock.now()


async def test_non_editable_record_cannot_be_corrected(memory: MemoryService) -> None:
    created = await memory.add(
        category=MemoryCategory.FINANCIAL, text="Statement total came to 5 lakh", user_editable=False
    )
    assert created.record is not None
    with pytest.raises(Forbidden):
        await memory.patch(created.record.id, MemoryPatch(text="changed"))
    assert await memory.delete(created.record.id)  # the owner can always delete


async def test_hard_delete_removes_row_and_vector(
    registry: PluginRegistry, memory: MemoryService, db: AsyncSession
) -> None:
    ids = await seed(memory)
    assert await memory.delete(ids["colour"])
    assert (
        await db.execute(text("SELECT count(*) FROM memory_records WHERE id = :i"), {"i": ids["colour"]})
    ).scalar_one() == 0
    assert await memory.recall("favourite colour blue", ctx=make_ctx(registry)) == []
    with pytest.raises(NotFound):
        await memory.get(ids["colour"])
    assert not await memory.delete(ids["colour"])


async def test_disabled_category_is_not_stored_and_not_recalled(
    registry: PluginRegistry, memory: MemoryService, db: AsyncSession
) -> None:
    kept = await memory.add(category=P, text="My favourite colour is blue")
    assert kept.stored
    await memory.update_settings(
        MemorySettings(
            categories=[MemoryCategorySetting(category=P, enabled=False, retention_days=None)],
            conversation_retention_days=30,
        )
    )
    skipped = await memory.add(category=P, text="I prefer window seats")
    assert skipped.outcome == "skipped_disabled" and skipped.record is None
    assert await raw_count(db) == 1
    assert await memory.recall("favourite colour", ctx=make_ctx(registry)) == []
    # The owner can still see and manage what is kept.
    assert len((await memory.list(category=P)).items) == 1
    # Switching it on again brings it back.
    await memory.update_settings(
        MemorySettings(
            categories=[MemoryCategorySetting(category=P, enabled=True, retention_days=None)],
            conversation_retention_days=30,
        )
    )
    assert await memory.recall("favourite colour", ctx=make_ctx(registry))


async def test_sensitivity_filtering_follows_privacy_mode_and_grants(
    registry: PluginRegistry, memory: MemoryService
) -> None:
    await memory.add(
        category=MemoryCategory.FINANCIAL,
        text="My salary is 90000 rupees a month",
        sensitivity=DataClass.FINANCIAL,
    )
    await memory.add(category=P, text="My salary review is in April")  # no sensitive words beyond 'salary'
    strict = await memory.recall("salary", ctx=make_ctx(registry))
    assert {i.sensitivity for i in strict} == {DataClass.FINANCIAL} or len(strict) >= 1
    assert any(i.sensitivity is DataClass.FINANCIAL for i in strict)
    cloud = make_ctx(registry, privacy_mode=PrivacyMode.CLOUD_INTELLIGENCE)
    assert all(
        i.sensitivity.rank <= DataClass.PERSONAL.rank for i in await memory.recall("salary", ctx=cloud)
    )
    await registry.service("permissions").set("cloud.financial", True)
    granted = await memory.recall("salary", ctx=cloud)
    assert any(i.sensitivity is DataClass.FINANCIAL for i in granted)


async def test_secrets_are_never_stored(memory: MemoryService, db: AsyncSession) -> None:
    assert (await memory.add(category=P, text="my wifi password is hunter2")).outcome == "rejected_secret"
    assert (
        await memory.add(category=P, text="harmless", sensitivity=DataClass.SECRET)
    ).outcome == "rejected_secret"
    assert await raw_count(db) == 0


async def test_sealed_text_is_absent_from_the_raw_table(memory: MemoryService, db: AsyncSession) -> None:
    sealed = await memory.add(category=MemoryCategory.FINANCIAL, text="My salary is 90000 rupees a month")
    plain = await memory.add(category=P, text="My favourite colour is blue")
    assert sealed.record is not None and plain.record is not None
    assert sealed.record.sensitivity is DataClass.FINANCIAL
    rows = (await db.execute(text("SELECT * FROM memory_records"))).mappings().all()
    by_id = {r["id"]: r for r in rows}
    sealed_dump = " ".join(str(v) for v in by_id[sealed.record.id].values())
    assert "salary" not in sealed_dump and "90000" not in sealed_dump
    assert by_id[sealed.record.id]["text_plain"] is None
    assert by_id[sealed.record.id]["text_enc"].startswith("v1.")
    assert by_id[plain.record.id]["text_plain"] == "My favourite colour is blue"
    assert (await memory.get(sealed.record.id)).text == "My salary is 90000 rupees a month"


async def test_retention_expiry_hides_then_sweeps(
    registry: PluginRegistry, memory: MemoryService, clock: FixedClock, db: AsyncSession
) -> None:
    await memory.update_settings(
        MemorySettings(
            categories=[
                MemoryCategorySetting(category=MemoryCategory.EPISODIC, enabled=True, retention_days=1)
            ],
            conversation_retention_days=30,
        )
    )
    short = await memory.add(category=MemoryCategory.EPISODIC, text="Visited the dentist yesterday")
    kept = await memory.add(category=P, text="Visited family in Jaipur")
    assert short.record is not None and short.record.expires_at == clock.now() + timedelta(days=1)
    assert kept.record is not None and kept.record.expires_at is None
    clock.advance(delta=timedelta(days=2))
    ctx = make_ctx(registry)
    assert await memory.recall("dentist", ctx=ctx) == []  # expired records are never recalled
    assert [r.id for r in (await memory.list()).items] == [kept.record.id]
    admin: MemoryAdmin = registry.service("memory_admin")
    assert await admin.sweep() == 1
    assert await raw_count(db) == 1


async def test_conversation_state_never_outlives_its_ttl(
    registry: PluginRegistry, memory: MemoryService, clock: FixedClock
) -> None:
    result = await memory.add(
        category=MemoryCategory.CONVERSATION_STATE, text="We are comparing two phones right now"
    )
    assert result.record is not None and result.record.expires_at == clock.now() + timedelta(hours=6)
    assert await memory.recall("comparing phones", ctx=make_ctx(registry))
    clock.advance(delta=timedelta(hours=6, seconds=1))
    assert await memory.recall("comparing phones", ctx=make_ctx(registry)) == []


async def test_retention_change_applies_to_existing_records(memory: MemoryService, clock: FixedClock) -> None:
    created = await memory.add(category=MemoryCategory.EPISODIC, text="Went to a concert last week")
    assert created.record is not None and created.record.expires_at is None
    await memory.update_settings(
        MemorySettings(
            categories=[
                MemoryCategorySetting(category=MemoryCategory.EPISODIC, enabled=True, retention_days=7)
            ],
            conversation_retention_days=30,
        )
    )
    assert (await memory.get(created.record.id)).expires_at == created.record.created_at + timedelta(days=7)


async def test_pagination_cursor(memory: MemoryService, clock: FixedClock) -> None:
    for n in range(5):
        clock.advance(1)
        await memory.add(category=P, text=f"Distinct fact number {n} about topic {n * 7}")
    first = await memory.list(limit=2)
    second = await memory.list(limit=2, cursor=first.next_cursor)
    third = await memory.list(limit=2, cursor=second.next_cursor)
    assert [len(p.items) for p in (first, second, third)] == [2, 2, 1] and third.next_cursor is None
    assert len({r.id for p in (first, second, third) for r in p.items}) == 5


# ---------------------------------------------------------------- proposals from a turn


async def test_explicit_requests_in_three_languages_need_no_model(
    registry: PluginRegistry, memory: MemoryService, gateway: FakeGateway
) -> None:
    ctx = make_ctx(registry, gateway=gateway)
    for utterance, expected in [
        ("Remember that I take my tea without sugar", "I take my tea without sugar"),
        ("yaad rakhna ki mera birthday 5 May hai", "mera birthday 5 May hai"),
        ("मेरा पसंदीदा रंग नीला है याद रखना", "मेरा पसंदीदा रंग नीला है"),
    ]:
        [result] = await memory.propose_from_turn(utterance, "Okay.", ctx)
        assert result.outcome == "created" and result.record is not None
        assert result.record.text == expected
        assert result.record.status == "active" and result.record.source == "conversation:conv_1"
    assert gateway.requests == []  # deterministic: the model was never consulted


async def test_explicit_sensitive_request_is_sealed_but_active(
    registry: PluginRegistry, memory: MemoryService, db: AsyncSession
) -> None:
    [result] = await memory.propose_from_turn(
        "remember that my salary is 90000 rupees", "", make_ctx(registry)
    )
    assert result.record is not None
    assert result.record.category is MemoryCategory.FINANCIAL and result.record.status == "active"
    assert "90000" not in str(
        (await db.execute(text("SELECT text_plain FROM memory_records"))).scalar_one_or_none()
    )


async def test_explicit_request_for_disabled_category_stores_nothing(
    registry: PluginRegistry, memory: MemoryService, db: AsyncSession
) -> None:
    await memory.update_settings(
        MemorySettings(
            categories=[MemoryCategorySetting(category=P, enabled=False, retention_days=None)],
            conversation_retention_days=30,
        )
    )
    [result] = await memory.propose_from_turn("remember that I like tea", "", make_ctx(registry))
    assert result.outcome == "skipped_disabled"
    assert await raw_count(db) == 0


async def test_remember_a_password_is_refused(registry: PluginRegistry, memory: MemoryService) -> None:
    [result] = await memory.propose_from_turn(
        "remember that my netflix password is hunter2", "", make_ctx(registry)
    )
    assert result.outcome == "rejected_secret"


def candidate(
    text: str, category: str = "profile", sensitivity: str = "personal", confidence: float = 0.9
) -> dict[str, object]:
    return {"text": text, "category": category, "sensitivity": sensitivity, "confidence": confidence}


async def test_implicit_candidates_and_the_pending_review_flow(
    registry: PluginRegistry, memory: MemoryService, gateway: FakeGateway
) -> None:
    gateway.push(
        {
            "candidates": [
                candidate("I like cycling on Sundays"),
                candidate("I am allergic to peanuts", sensitivity="health"),
                candidate("The owner won a lottery", confidence=0.95),  # not grounded in the message
                candidate("I like jazz", confidence=0.3),  # too unsure
                candidate("I like jazz music", sensitivity="secret"),  # claimed secret: dropped
            ]
        }
    )
    ctx = make_ctx(registry, gateway=gateway)
    results = await memory.propose_from_turn(
        "I like cycling on Sundays and I am allergic to peanuts, I like jazz music", "Noted.", ctx
    )
    assert [r.outcome for r in results] == ["created", "created"]
    [personal, health] = [r.record for r in results]
    assert personal is not None and health is not None
    assert personal.status == "active"
    assert health.status == "pending_review" and health.sensitivity is DataClass.HEALTH
    assert gateway.requests[0].data_classes == frozenset({DataClass.HEALTH})  # the prompt is labelled
    # Pending records are not recalled until the owner approves.
    assert await memory.recall("peanuts allergic", ctx=ctx) == []
    assert [r.id for r in (await memory.list(status="pending_review")).items] == [health.id]
    approved = await memory.patch(health.id, MemoryPatch(status="active"))
    assert approved.last_verified_at is not None
    assert (await memory.recall("peanuts allergic", ctx=ctx))[0].id == health.id


async def test_no_implicit_capture_when_tainted_without_model_or_on_failure(
    registry: PluginRegistry, memory: MemoryService, gateway: FakeGateway
) -> None:
    from app.core.types import TaskClass
    from app.providers.types import NoPermittedModel

    text = "I like cycling on Sundays a lot"
    tainted = make_ctx(registry, gateway=gateway, tainted=True)
    assert await memory.propose_from_turn(text, "", tainted) == []
    assert gateway.requests == []
    assert await memory.propose_from_turn(text, "", make_ctx(registry, gateway=None)) == []
    gateway.push(NoPermittedModel(TaskClass.ROUTINE_CHAT))
    assert await memory.propose_from_turn(text, "", make_ctx(registry, gateway=gateway)) == []
    gateway.push("this is not json")
    assert await memory.propose_from_turn(text, "", make_ctx(registry, gateway=gateway)) == []


async def test_gateway_embeddings_are_used_with_the_records_data_classes(
    registry: PluginRegistry, memory: MemoryService, gateway: FakeGateway
) -> None:
    await memory.add(category=MemoryCategory.FINANCIAL, text="My salary is 90000 rupees", gateway=gateway)
    texts, classes, mode = gateway.embed_calls[0]
    assert classes == frozenset({DataClass.FINANCIAL}) and mode is PrivacyMode.STRICT_PRIVATE
    assert texts == ["My salary is 90000 rupees"]
