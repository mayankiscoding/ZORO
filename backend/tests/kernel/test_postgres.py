"""Kernel end to end on PostgreSQL + pgvector. Runs only with ZORO_TEST_DATABASE_URL set
(use a throwaway database: this test drops and recreates every table)."""

from __future__ import annotations

import httpx
import pytest
from sqlalchemy import select, text

from app.core.clock import FixedClock
from app.core.errors import ApprovalReplayed, ProofReplayed
from app.core.settings import Settings
from app.core.types import ApprovalLevel, RiskLevel
from app.db.discovery import import_models
from app.db.session import Database, drop_all
from app.main import create_app
from app.plugins import PluginRegistry
from app.security.models import ApprovalRow, AuditRow, IntegrationCredential
from app.tools import Completed, NeedsApproval
from tests.fakes.devices import DeviceSigner
from tests.kernel.conftest import make_ctx, make_tool

pytestmark = pytest.mark.postgres


async def test_kernel_services_on_postgres(settings: Settings, clock: FixedClock) -> None:
    assert settings.database_url.startswith("postgresql")
    import_models(["app.security", "app.tools"])
    scratch = Database.from_url(settings.database_url)
    await drop_all(scratch.engine)
    await scratch.dispose()

    app = create_app(settings, plugin_modules=(), clock=clock)
    reg: PluginRegistry = app.state.registry
    async with app.router.lifespan_context(app):
        async with reg.service("session_factory")() as session:
            column_types = dict(
                (
                    await session.execute(
                        text(
                            "SELECT table_name || '.' || column_name, data_type FROM information_schema.columns "
                            "WHERE table_name IN ('devices', 'audit_log', 'security_settings')"
                        )
                    )
                ).all()
            )
        assert column_types["devices.capabilities"] == "jsonb"
        assert column_types["security_settings.value"] == "jsonb"
        assert column_types["audit_log.seq"] == "bigint"
        assert column_types["audit_log.ts"] == "timestamp with time zone"

        # pairing, session, signed settings change, replay guard (unique violation path)
        signer = DeviceSigner(now=clock.now)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as http:
            issued = await reg.service("devices").create_pairing_code()
            paired = await http.post(
                "/v1/auth/pair", json=signer.pair_request(issued.code).model_dump(mode="json")
            )
            assert paired.status_code == 200, paired.text
            signer.device_id = paired.json()["device_id"]
            reuse = await http.post(
                "/v1/auth/pair", json=DeviceSigner().pair_request(issued.code).model_dump(mode="json")
            )
            assert reuse.json()["code"] == "pairing_code_invalid"
            challenge = (await http.post("/v1/auth/challenge", json={"device_id": signer.device_id})).json()
            token = await http.post(
                "/v1/auth/token", json=signer.sign_auth(challenge["nonce"]).model_dump(mode="json")
            )
            headers = {"Authorization": f"Bearer {token.json()['access_token']}"}
            proof = signer.sign_proof("set_permission", "cloud.financial=true").model_dump(mode="json")
            granted = await http.put(
                "/v1/security/permissions/cloud.financial",
                json={"granted": True, "proof": proof},
                headers=headers,
            )
            assert granted.status_code == 200, granted.text
            replay = await http.put(
                "/v1/security/permissions/cloud.financial",
                json={"granted": True, "proof": proof},
                headers=headers,
            )
            assert replay.status_code == 409 and replay.json()["code"] == "proof_replayed"
            state = (await http.get("/v1/security/state", headers=headers)).json()
            assert {p["key"]: p["granted"] for p in state["permissions"]}["cloud.financial"] is True
        with pytest.raises(ProofReplayed):
            await reg.service("proofs").verify(
                signer.sign_proof("set_permission", "cloud.financial=true"),
                action="set_permission",
                subject="cloud.financial=true",
            )

        # secrets, approvals and the executor journal
        await reg.service("secrets").put("spotify", "tok-pg")
        await reg.service("secrets").put("spotify", "tok-pg-2")
        assert await reg.service("secrets").get("spotify") == "tok-pg-2"

        reg.add_tool(make_tool("test.send_note", risk=RiskLevel.HIGH))
        executor = reg.service("tool_executor")
        ctx = make_ctx(reg, device_id=signer.device_id, user_initiated=True)
        pending = await executor.execute(ctx, "test.send_note", {"text": "नमस्ते", "count": 2}, call_id="pg1")
        assert isinstance(pending, NeedsApproval) and pending.request.level is ApprovalLevel.CONFIRM
        decision = signer.sign_approval(pending.request)
        done = await executor.resume_with_approval(ctx, "pg1", decision)
        assert isinstance(done, Completed) and done.result.model_dump() == {"echoed": "नमस्तेनमस्ते"}
        with pytest.raises(ApprovalReplayed):
            await reg.service("approvals").verify(decision)
        again = await executor.execute(ctx, "test.send_note", {"text": "नमस्ते", "count": 2}, call_id="pg1")
        assert isinstance(again, Completed)  # recorded outcome, not a second run

        # audit chain on PostgreSQL, then tamper with it
        audit = reg.service("audit")
        status = await audit.verify_chain()
        assert status.ok and status.records >= 6
        async with reg.service("session_factory")() as session:
            assert (await session.execute(select(ApprovalRow.status))).scalars().all() == ["approved"]
            assert len((await session.execute(select(IntegrationCredential))).scalars().all()) == 1
            victim = (
                await session.execute(select(AuditRow.id).order_by(AuditRow.seq).limit(1).offset(2))
            ).scalar_one()
            await session.execute(
                text("UPDATE audit_log SET decision = 'allowed' WHERE id = :id"), {"id": victim}
            )
            await session.execute(
                text("UPDATE audit_log SET detail = 'edited' WHERE id = :id"), {"id": victim}
            )
            await session.commit()
        broken = await audit.verify_chain()
        assert broken.ok is False and broken.broken_at == victim and broken.reason == "hash_mismatch"
