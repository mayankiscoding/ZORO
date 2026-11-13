"""Checkpointer selection, encryption at rest, and a suspended turn surviving a restart."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from app.core.settings import Settings
from app.orchestrator.checkpoint import (
    CheckpointerHandle,
    DataKeyCipher,
    checkpoint_kind,
    postgres_conninfo,
    sqlite_checkpoint_path,
)
from app.orchestrator.service import TurnService
from app.orchestrator.supervisor import Supervisor
from app.plugins import PluginRegistry
from app.schemas.turns import ResumeRequest
from app.security.sessions import AuthedDevice
from tests.conftest import PairedDevice
from tests.orchestrator.conftest import of, text_of, turn_request
from tests.orchestrator.toolkit import Toolbox


def _settings(tmp_path: Path, **kw: Any) -> Settings:
    fields: dict[str, Any] = {"_env_file": None, "env": "development", "local_dir": tmp_path / "local"}
    fields.update(kw)
    return Settings(**fields)


def test_checkpointer_kind_follows_the_database(tmp_path: Path, settings: Settings) -> None:
    assert checkpoint_kind(settings) == "memory"  # tests
    dev = _settings(tmp_path, database_url=f"sqlite+aiosqlite:///{tmp_path / 'zoro.db'}")
    assert checkpoint_kind(dev) == "sqlite"
    assert sqlite_checkpoint_path(dev) == tmp_path / "zoro.db.checkpoints"
    assert checkpoint_kind(_settings(tmp_path, database_url="sqlite+aiosqlite:///:memory:")) == "memory"
    pg = _settings(tmp_path, database_url="postgresql+psycopg://zoro:pw@db.internal:5432/zoro")
    assert checkpoint_kind(pg) == "postgres"
    assert postgres_conninfo(pg) == "postgresql://zoro:pw@db.internal:5432/zoro"
    assert checkpoint_kind(_settings(tmp_path, database_url="postgres://zoro@localhost/zoro")) == "postgres"


def test_checkpoint_cipher_round_trip_and_tamper_detection() -> None:
    cipher = DataKeyCipher(b"k" * 32)
    name, sealed = cipher.encrypt(b"turn state")
    assert b"turn state" not in sealed and cipher.decrypt(name, sealed) == b"turn state"
    with pytest.raises(ValueError, match="unsupported"):
        cipher.decrypt("aes", sealed)
    with pytest.raises(Exception):  # noqa: B017 - any authentication failure
        cipher.decrypt(name, sealed[:-1] + bytes([sealed[-1] ^ 1]))


async def test_suspended_turn_survives_a_restart_with_the_sqlite_saver(
    registry: PluginRegistry,
    box: Toolbox,
    authed: AuthedDevice,
    paired_device: PairedDevice,
    settings: Settings,
) -> None:
    store = registry.service("conversations")

    def boot() -> tuple[TurnService, CheckpointerHandle]:
        handle = CheckpointerHandle(settings, kind="sqlite")
        return TurnService(registry, Supervisor(registry), store, handle), handle

    first, handle = boot()
    await first.startup()
    stream = await first.start(turn_request("send a message to Asha saying landed safely"), authed)
    events = [event async for event in stream]
    approval = of(events, "approval_required")[0].approval
    await first.shutdown()  # the process goes away with the turn still waiting

    path = sqlite_checkpoint_path(settings)
    assert path.exists()
    raw = b"".join(p.read_bytes() for p in path.parent.glob(path.name + "*"))
    assert b"Asha" not in raw and b"landed safely" not in raw  # checkpoints are encrypted

    second, handle2 = boot()
    await second.startup()
    decision = paired_device.signer.sign_approval(approval)
    resumed = [
        e async for e in await second.resume(events[0].turn_id, ResumeRequest(approval=decision), authed)
    ]
    assert text_of(resumed) == "Message sent to Asha." and box.calls["send"] == 1
    assert of(resumed, "turn_completed")[0].usage.tool_calls == 1
    await second.shutdown()
    assert handle.saver is None and handle2.saver is None


async def test_memory_saver_reports_lost_state_instead_of_hanging(
    registry: PluginRegistry, box: Toolbox, authed: AuthedDevice, paired_device: PairedDevice
) -> None:
    from app.core.errors import Conflict
    from app.core.types import TurnStatus

    service = registry.service("turn_service")
    events = [e async for e in await service.start(turn_request("set an alarm for 6:00"), authed)]
    turn_id = events[0].turn_id
    await registry.service("checkpoints").delete_threads([turn_id])  # as after a restart in memory mode
    action = of(events, "device_action")[0].action
    from datetime import UTC, datetime

    from app.schemas.turns import DeviceActionResult

    result = DeviceActionResult(action_id=action.action_id, ok=True, result={}, executed_at=datetime.now(UTC))
    with pytest.raises(Conflict) as lost:
        await service.resume(turn_id, ResumeRequest(device_result=result), authed)
    assert lost.value.error_code == "turn_state_lost"
    assert (await registry.service("conversations").get_turn(turn_id)).status is TurnStatus.FAILED


@pytest.mark.postgres
async def test_postgres_saver_opens_and_stores_a_checkpoint(settings: Settings) -> None:
    handle = CheckpointerHandle(settings, kind="postgres")
    saver = await handle.open()
    try:
        assert type(saver).__name__ == "AsyncPostgresSaver"
        assert await saver.aget_tuple({"configurable": {"thread_id": "turn_absent"}}) is None
    finally:
        await handle.close()
