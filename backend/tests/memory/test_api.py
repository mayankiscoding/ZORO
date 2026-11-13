"""/v1/memory as the Swift MemoryClient calls it, and the signed operations."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import httpx
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import FixedClock
from app.core.types import MemoryCategory
from app.memory.service import MemoryService
from app.plugins import PluginRegistry
from tests.conftest import PairDevice, PairedDevice

P = MemoryCategory.PROFILE


async def create(client: httpx.AsyncClient, dev: PairedDevice, body: dict[str, Any]) -> httpx.Response:
    return await client.post("/v1/memory", json=body, headers=dev.headers)


async def test_routes_require_a_signed_in_device(client: httpx.AsyncClient) -> None:
    for method, path in [
        ("GET", "/v1/memory"),
        ("GET", "/v1/memory/search?q=x"),
        ("GET", "/v1/memory/settings"),
    ]:
        response = await client.request(method, path)
        assert response.status_code == 401 and response.json()["code"] == "unauthorized"


async def test_create_list_search_patch_delete_round_trip(
    client: httpx.AsyncClient, paired_device: PairedDevice
) -> None:
    created = await create(
        client, paired_device, {"category": "profile", "text": "My favourite colour is blue"}
    )
    assert created.status_code == 201
    record = created.json()
    assert record["category"] == "profile" and record["sensitivity"] == "personal"
    assert record["status"] == "active" and record["source"] == "user" and record["user_editable"] is True
    for key in ("id", "confidence", "created_at", "last_verified_at", "expires_at"):
        assert key in record
    await create(
        client,
        paired_device,
        {"category": "episodic", "text": "Flew to Pune last March", "sensitivity": "personal"},
    )

    listing = (await client.get("/v1/memory", headers=paired_device.headers)).json()
    assert len(listing["items"]) == 2 and listing["next_cursor"] is None
    only = (
        await client.get("/v1/memory?category=episodic&status=active&limit=1", headers=paired_device.headers)
    ).json()
    assert [i["category"] for i in only["items"]] == ["episodic"]
    paged = (await client.get("/v1/memory?limit=1", headers=paired_device.headers)).json()
    assert paged["next_cursor"] == "1"
    rest = (await client.get("/v1/memory?limit=1&cursor=1", headers=paired_device.headers)).json()
    assert len(rest["items"]) == 1 and rest["items"][0]["id"] != paged["items"][0]["id"]

    found = (
        await client.get("/v1/memory/search?q=favourite%20colour&limit=5", headers=paired_device.headers)
    ).json()
    assert found["items"][0]["id"] == record["id"]
    assert (await client.get("/v1/memory/search?q=", headers=paired_device.headers)).status_code == 422

    verified = await client.patch(
        f"/v1/memory/{record['id']}", json={"verified": True}, headers=paired_device.headers
    )
    assert verified.status_code == 200 and verified.json()["last_verified_at"] is not None
    fixed = await client.patch(
        f"/v1/memory/{record['id']}",
        json={"text": "My favourite colour is green"},
        headers=paired_device.headers,
    )
    assert fixed.json()["text"] == "My favourite colour is green" and fixed.json()["source"] == "user"
    archived = await client.patch(
        f"/v1/memory/{record['id']}", json={"status": "archived"}, headers=paired_device.headers
    )
    assert archived.json()["status"] == "archived"

    assert (
        await client.delete(f"/v1/memory/{record['id']}", headers=paired_device.headers)
    ).status_code == 204
    gone = await client.delete(f"/v1/memory/{record['id']}", headers=paired_device.headers)
    assert gone.status_code == 404 and gone.json()["code"] == "memory_not_found"
    assert (
        await client.patch("/v1/memory/mem_nope", json={"verified": True}, headers=paired_device.headers)
    ).status_code == 404


async def test_create_refuses_secrets_and_disabled_categories(
    client: httpx.AsyncClient, paired_device: PairedDevice
) -> None:
    secret = await create(client, paired_device, {"category": "profile", "text": "my otp is 483920"})
    assert secret.status_code == 400 and secret.json()["code"] == "memory_secret_refused"
    marked = await create(
        client, paired_device, {"category": "profile", "text": "hello", "sensitivity": "secret"}
    )
    assert marked.status_code == 400
    settings = (await client.get("/v1/memory/settings", headers=paired_device.headers)).json()
    for item in settings["categories"]:
        if item["category"] == "visual":
            item["enabled"] = False
    put = await client.put("/v1/memory/settings", json=settings, headers=paired_device.headers)
    assert put.status_code == 200
    off = await create(client, paired_device, {"category": "visual", "text": "A photo of the beach"})
    assert off.status_code == 409 and off.json()["code"] == "memory_category_disabled"


async def test_settings_shape_and_validation(client: httpx.AsyncClient, paired_device: PairedDevice) -> None:
    body = (await client.get("/v1/memory/settings", headers=paired_device.headers)).json()
    assert [c["category"] for c in body["categories"]] == [c.value for c in MemoryCategory]
    assert all(c["enabled"] is True and c["retention_days"] is None for c in body["categories"])
    assert body["conversation_retention_days"] == 30
    body["categories"][0]["retention_days"] = 90
    body["conversation_retention_days"] = 7
    updated = (await client.put("/v1/memory/settings", json=body, headers=paired_device.headers)).json()
    assert updated["categories"][0]["retention_days"] == 90 and updated["conversation_retention_days"] == 7
    again = (await client.get("/v1/memory/settings", headers=paired_device.headers)).json()
    assert again == updated
    body["categories"][0]["retention_days"] = 0
    bad = await client.put("/v1/memory/settings", json=body, headers=paired_device.headers)
    assert bad.status_code == 422


async def test_pending_review_is_listed_and_approved_through_the_api(
    client: httpx.AsyncClient, paired_device: PairedDevice, memory: MemoryService
) -> None:
    pending = await memory.add(
        category=P,
        text="I am allergic to peanuts",
        status="pending_review",
        source="conversation:c1",
        confidence=0.8,
    )
    assert pending.record is not None
    queue = (await client.get("/v1/memory?status=pending_review", headers=paired_device.headers)).json()
    assert [i["id"] for i in queue["items"]] == [pending.record.id] and queue["items"][0][
        "sensitivity"
    ] == "health"
    ok = await client.patch(
        f"/v1/memory/{pending.record.id}", json={"status": "active"}, headers=paired_device.headers
    )
    assert ok.json()["status"] == "active" and ok.json()["last_verified_at"] is not None


# ---------------------------------------------------------------- signed operations


async def test_export_needs_a_valid_proof_and_is_audited(
    client: httpx.AsyncClient, paired_device: PairedDevice, memory: MemoryService, registry: PluginRegistry
) -> None:
    await memory.add(category=P, text="My favourite colour is blue")
    await memory.add(category=MemoryCategory.FINANCIAL, text="My salary is 90000 rupees a month")
    signer = paired_device.signer
    proof = signer.sign_proof("export_memory", "all")
    response = await client.post(
        "/v1/memory/export", json={"proof": proof.model_dump(mode="json")}, headers=paired_device.headers
    )
    assert response.status_code == 200
    assert "attachment" in response.headers["content-disposition"]
    document = response.json()
    assert document["format"] == "zoro-memory-export-v1" and document["count"] == 2
    texts = {r["text"] for r in document["records"]}
    assert "My salary is 90000 rupees a month" in texts  # sealed at rest, opened for the owner's export
    assert {"edited_by_owner", "mentions", "source", "confidence"} <= set(document["records"][0])

    page = await registry.service("audit").list(limit=50)
    exports = [r for r in page.items if r.action == "memory.export"]
    assert exports and exports[0].risk is not None and exports[0].risk.value == "critical"
    assert exports[0].decision == "approved" and "90000" not in exports[0].detail

    one = signer.sign_proof("export_memory", "profile")
    scoped = await client.post(
        "/v1/memory/export",
        json={"category": "profile", "proof": one.model_dump(mode="json")},
        headers=paired_device.headers,
    )
    assert scoped.status_code == 200 and scoped.json()["count"] == 1


async def test_export_refuses_replayed_wrong_stale_and_wrong_key_proofs(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    pair_device: PairDevice,
    memory: MemoryService,
    registry: PluginRegistry,
    clock: FixedClock,
) -> None:
    await memory.add(category=P, text="My favourite colour is blue")
    signer = paired_device.signer

    async def export(body: dict[str, Any], dev: PairedDevice = paired_device) -> httpx.Response:
        return await client.post("/v1/memory/export", json=body, headers=dev.headers)

    good = signer.sign_proof("export_memory", "all")
    assert (await export({"proof": good.model_dump(mode="json")})).status_code == 200
    replay = await export({"proof": good.model_dump(mode="json")})
    assert replay.status_code == 409 and replay.json()["code"] == "proof_replayed"

    wrong_subject = signer.sign_proof("export_memory", "profile")  # signed for profile, asked for all
    assert (await export({"proof": wrong_subject.model_dump(mode="json")})).json()["code"] == "proof_invalid"
    wrong_action = signer.sign_proof("delete_memory_category", "all")
    assert (await export({"proof": wrong_action.model_dump(mode="json")})).json()["code"] == "proof_invalid"
    auth_key = signer.sign_proof(
        "export_memory", "all", key="auth", signed_at=clock.now() + timedelta(seconds=1)
    )
    assert (await export({"proof": auth_key.model_dump(mode="json")})).json()["code"] == "proof_invalid"
    stale = signer.sign_proof("export_memory", "all", signed_at=clock.now() - timedelta(minutes=10))
    assert (await export({"proof": stale.model_dump(mode="json")})).json()["code"] == "proof_stale"
    other = await pair_device(name="Other phone")
    foreign = other.signer.sign_proof("export_memory", "all", signed_at=clock.now() + timedelta(seconds=2))
    assert (await export({"proof": foreign.model_dump(mode="json")})).json()[
        "code"
    ] == "proof_invalid"  # not this session's device
    assert (await export({})).status_code == 422
    forged = good.model_copy(
        update={"signed_at": clock.now() + timedelta(seconds=3), "signature_b64": good.signature_b64}
    )
    assert (await export({"proof": forged.model_dump(mode="json")})).json()["code"] == "proof_invalid"

    denied = [
        r
        for r in (await registry.service("audit").list(limit=100)).items
        if r.action == "memory.export" and r.decision == "denied"
    ]
    assert len(denied) >= 5


async def test_delete_category_needs_a_valid_proof_and_removes_everything(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    memory: MemoryService,
    db: AsyncSession,
    registry: PluginRegistry,
) -> None:
    await memory.add(category=P, text="My favourite colour is blue")
    await memory.add(category=P, text="I prefer window seats on flights")
    await memory.add(category=MemoryCategory.EPISODIC, text="Visited the dentist yesterday")
    signer = paired_device.signer
    url = "/v1/memory/categories/profile/delete"

    wrong = signer.sign_proof("delete_memory_category", "episodic")
    refused = await client.post(
        url, json={"proof": wrong.model_dump(mode="json")}, headers=paired_device.headers
    )
    assert refused.status_code == 403 and refused.json()["code"] == "proof_invalid"
    assert (await db.execute(text("SELECT count(*) FROM memory_records"))).scalar_one() == 3

    good = signer.sign_proof("delete_memory_category", "profile")
    done = await client.post(url, json={"proof": good.model_dump(mode="json")}, headers=paired_device.headers)
    assert done.status_code == 204
    remaining = (await db.execute(text("SELECT category FROM memory_records"))).scalars().all()
    assert remaining == ["episodic"]
    replay = await client.post(
        url, json={"proof": good.model_dump(mode="json")}, headers=paired_device.headers
    )
    assert replay.status_code == 409 and replay.json()["code"] == "proof_replayed"
    assert (
        await client.post(
            "/v1/memory/categories/nonsense/delete",
            json={"proof": good.model_dump(mode="json")},
            headers=paired_device.headers,
        )
    ).status_code == 422
    audit = [
        r
        for r in (await registry.service("audit").list(limit=50)).items
        if r.action == "memory.delete_category"
    ]
    assert {r.decision for r in audit} == {"approved", "denied"}


async def test_sweeper_runs_with_the_app_and_stops_on_demand(registry: PluginRegistry) -> None:
    from app.memory.admin import RetentionSweeper

    admin = registry.service("memory_admin")
    sweeper = RetentionSweeper(admin, interval_s=0.01)
    await sweeper.start()
    assert sweeper.running
    await sweeper.stop()
    assert not sweeper.running
    assert registry.startup_hooks and registry.shutdown_hooks  # the plugin registered both


async def test_sweeper_survives_a_failing_pass(registry: PluginRegistry) -> None:
    import asyncio

    from app.memory.admin import RetentionSweeper

    calls = 0

    class Flaky:
        async def sweep(self) -> int:
            nonlocal calls
            calls += 1
            raise RuntimeError("boom")

    sweeper = RetentionSweeper(Flaky(), interval_s=0.01)  # type: ignore[arg-type]
    await sweeper.start()
    await asyncio.sleep(0.1)
    assert sweeper.running and calls >= 2
    await sweeper.stop()
