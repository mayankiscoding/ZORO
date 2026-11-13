"""Audit log: hash chain, append-only, tamper detection, redaction, paging."""

from __future__ import annotations

import asyncio

import pytest
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.types import DataClass, RiskLevel
from app.plugins import PluginRegistry
from app.security.audit import GENESIS_HASH, AuditLog, record_hash
from app.security.models import AuditRow


async def _seed(audit: AuditLog, count: int = 5) -> list[str]:
    ids = []
    for index in range(count):
        record = await audit.append(
            actor="finance",
            action="tool.run",
            decision="allowed",
            tool="finance.spending_summary",
            risk=RiskLevel.LOW,
            data_classes=[DataClass.FINANCIAL, DataClass.PERSONAL],
            detail=f"ok n={index}",
        )
        ids.append(record.id)
    return ids


async def test_chain_links_every_record(registry: PluginRegistry) -> None:
    audit: AuditLog = registry.service("audit")
    assert (await audit.verify_chain()).ok  # empty chain is intact
    first = await audit.append(actor="system", action="server.started")
    second = await audit.append(actor="dev_1", action="security.set_privacy_mode", decision="approved")
    assert first.prev_hash == GENESIS_HASH
    assert second.prev_hash == first.hash
    assert len(first.hash) == 64 and first.hash != second.hash
    assert first.decision == "info"
    status = await audit.verify_chain()
    assert status.ok and status.records == 2 and status.broken_at is None


async def test_record_shape_and_paging(registry: PluginRegistry) -> None:
    audit: AuditLog = registry.service("audit")
    ids = await _seed(audit, 5)
    page = await audit.list(limit=2)
    assert [r.id for r in page.items] == [ids[4], ids[3]]  # newest first
    assert page.next_cursor is not None
    item = page.items[0]
    assert item.tool == "finance.spending_summary" and item.risk is RiskLevel.LOW
    assert item.data_classes == [DataClass.FINANCIAL, DataClass.PERSONAL]
    assert item.ts.tzinfo is not None
    rest = await audit.list(cursor=page.next_cursor, limit=10)
    assert [r.id for r in rest.items] == [ids[2], ids[1], ids[0]]
    assert rest.next_cursor is None


async def test_concurrent_appends_keep_one_chain(registry: PluginRegistry) -> None:
    audit: AuditLog = registry.service("audit")
    await asyncio.gather(*(audit.append(actor="a", action=f"event.{i}") for i in range(25)))
    status = await audit.verify_chain(batch=7)
    assert status.ok and status.records == 25


@pytest.mark.parametrize(
    ("column", "value"),
    [("detail", "ok n=999"), ("decision", "denied"), ("actor", "someone_else"), ("tool", "finance.transfer")],
)
async def test_editing_a_record_is_detected(
    registry: PluginRegistry, db: AsyncSession, column: str, value: str
) -> None:
    audit: AuditLog = registry.service("audit")
    ids = await _seed(audit)
    statement = f"UPDATE audit_log SET {column} = :value WHERE id = :id"  # noqa: S608 - fixed test columns
    await db.execute(text(statement), {"value": value, "id": ids[2]})
    await db.commit()
    status = await audit.verify_chain()
    assert status.ok is False
    assert status.broken_at == ids[2] and status.reason == "hash_mismatch"
    assert status.records == 2


async def test_recomputing_one_hash_still_breaks_the_next_link(
    registry: PluginRegistry, db: AsyncSession
) -> None:
    audit: AuditLog = registry.service("audit")
    ids = await _seed(audit)
    row = (await db.execute(select(AuditRow).where(AuditRow.id == ids[1]))).scalar_one()
    forged_detail = "ok n=777"
    row_copy = AuditRow(
        id=row.id, ts=row.ts, actor=row.actor, action=row.action, tool=row.tool, risk=row.risk,
        decision=row.decision, data_classes=row.data_classes, detail=forged_detail,
    )  # fmt: skip
    forged_hash = record_hash(row.prev_hash, row_copy)
    await db.execute(
        text("UPDATE audit_log SET detail = :detail, hash = :hash WHERE id = :id"),
        {"detail": forged_detail, "hash": forged_hash, "id": ids[1]},
    )
    await db.commit()
    status = await audit.verify_chain()
    assert status.ok is False
    assert status.broken_at == ids[2] and status.reason == "broken_link"


async def test_deleting_a_record_is_detected(registry: PluginRegistry, db: AsyncSession) -> None:
    audit: AuditLog = registry.service("audit")
    ids = await _seed(audit)
    await db.execute(text("DELETE FROM audit_log WHERE id = :id"), {"id": ids[0]})
    await db.commit()
    status = await audit.verify_chain()
    assert status.ok is False and status.broken_at == ids[1] and status.reason == "broken_link"


async def test_orm_refuses_updates_and_deletes(registry: PluginRegistry, db: AsyncSession) -> None:
    audit: AuditLog = registry.service("audit")
    ids = await _seed(audit, 1)
    row = (await db.execute(select(AuditRow).where(AuditRow.id == ids[0]))).scalar_one()
    row.detail = "rewritten"
    with pytest.raises(RuntimeError, match="append-only"):
        await db.flush()
    await db.rollback()
    row = (await db.execute(select(AuditRow).where(AuditRow.id == ids[0]))).scalar_one()
    await db.delete(row)
    with pytest.raises(RuntimeError, match="append-only"):
        await db.flush()
    await db.rollback()
    assert (await audit.verify_chain()).ok


async def test_detail_is_redacted_and_truncated(registry: PluginRegistry) -> None:
    audit: AuditLog = registry.service("audit")
    record = await audit.append(
        actor="communication",
        action="tool.run",
        detail="sent to person@example.com token=abc123secret card 4111 1111 1111 1111 " + "x" * 2000,
    )
    assert "person@example.com" not in record.detail
    assert "abc123secret" not in record.detail
    assert "4111" not in record.detail
    assert len(record.detail) <= 500
    assert (await audit.verify_chain()).ok
