"""Alembic migrations on SQLite and PostgreSQL, CLI commands, and the LangGraph PostgreSQL checkpointer.

These tests are synchronous on purpose: Alembic's env.py runs the async engine with asyncio.run.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from collections.abc import Iterator
from pathlib import Path

import psycopg
import pytest
from alembic.autogenerate import compare_metadata
from alembic.runtime.migration import MigrationContext
from sqlalchemy import create_engine as create_sync_engine
from sqlalchemy import inspect, text

from app.cli import main as cli_main
from app.core.settings import Settings
from app.db import migrate
from app.db.base import Base
from app.db.discovery import import_models
from app.db.session import create_engine, init_db
from tests.integration.platform.pg_everywhere import (
    ENV_URL,
    _admin_conninfo,
    isolated_database_url,
    schema_url,
)


def _sync_url(url: str) -> str:
    return url.replace("+aiosqlite", "").replace("+psycopg", "+psycopg")


def _app_tables() -> set[str]:
    """Tables of the application's own models (tests may register extra test-only tables)."""
    import_models()
    return {m.local_table.name for m in Base.registry.mappers if m.class_.__module__.startswith("app.")}


def _drift(url: str) -> list[object]:
    """Differences between the migrated database and the app's models (ignoring `ixm_*` extras,
    LangGraph checkpoint tables and test-only tables other tests put on the metadata)."""
    app_tables = _app_tables()

    def include(obj: object, name: str | None, type_: str, reflected: bool, compare_to: object) -> bool:
        if reflected and compare_to is None and name and name.startswith(("ixm_", "checkpoint")):
            return False
        table = getattr(obj, "table", obj) if type_ != "table" else obj
        table_name = getattr(table, "name", name)
        return not (type_ in ("table", "index", "column") and table_name not in app_tables and not reflected)

    engine = create_sync_engine(_sync_url(url))
    try:
        with engine.connect() as conn:
            ctx = MigrationContext.configure(conn, opts={"compare_type": False, "include_object": include})
            return list(compare_metadata(ctx, Base.metadata))
    finally:
        engine.dispose()


@pytest.fixture
def sqlite_url(tmp_path: Path) -> str:
    return f"sqlite+aiosqlite:///{tmp_path / 'migrate.db'}"


def test_head_is_a_single_revision() -> None:
    assert migrate.head_revision() == "0002"


def test_sqlite_upgrade_matches_models_and_downgrades_cleanly(sqlite_url: str) -> None:
    state = migrate.upgrade(sqlite_url)
    assert state.at_head
    import_models()
    assert set(state.app_tables) >= _app_tables()
    assert _drift(sqlite_url) == []
    down = migrate.downgrade(sqlite_url, "base")
    assert down.current is None and down.app_tables == []


def test_init_db_adopts_a_create_all_database(sqlite_url: str) -> None:
    async def create_all() -> None:
        engine = create_engine(sqlite_url)
        await init_db(engine)
        await engine.dispose()

    asyncio.run(create_all())
    with pytest.raises(migrate.SchemaNotManaged):
        migrate.upgrade(sqlite_url)
    action, state = migrate.init_database(sqlite_url)
    assert action == "adopted" and state.at_head
    action, state = migrate.init_database(sqlite_url)
    assert action == "up_to_date"


def test_cli_migrate_and_status(
    sqlite_url: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ZORO_DATABASE_URL", sqlite_url)
    monkeypatch.setenv("ZORO_ENV", "test")
    from app.core.settings import get_settings

    get_settings.cache_clear()
    try:
        assert cli_main(["migrate"]) == 0
        assert cli_main(["migrate", "--status"]) == 0
        out = capsys.readouterr().out
        assert "revision 0002; head 0002" in out
        assert cli_main(["migrate", "--downgrade", "base"]) == 0
        assert cli_main(["init-db"]) == 0
        assert "Database created" in capsys.readouterr().out
    finally:
        get_settings.cache_clear()


def test_cli_capabilities_markdown(
    capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("ZORO_ENV", "test")
    from app.core.settings import get_settings

    get_settings.cache_clear()
    try:
        assert cli_main(["capabilities"]) == 0
    finally:
        get_settings.cache_clear()
    out = capsys.readouterr().out
    assert out.startswith("# Integration capability matrix")
    assert "## Needs credentials" in out and "`models.gemini`" in out


# ------------------------------------------------------------------------------ PostgreSQL


@pytest.fixture
def pg_schema_url() -> Iterator[str]:
    raw = os.environ.get(ENV_URL)
    if not raw:
        pytest.skip("needs PostgreSQL + pgvector: set ZORO_TEST_DATABASE_URL")
    url = isolated_database_url(raw)
    schema = f"m_{uuid.uuid4().hex[:16]}"
    admin = _admin_conninfo(url)
    with psycopg.connect(admin, autocommit=True) as conn:
        conn.execute(f'CREATE SCHEMA "{schema}"')
    try:
        yield schema_url(url, schema)
    finally:
        with psycopg.connect(admin, autocommit=True) as conn:
            conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')


@pytest.mark.postgres
def test_postgres_upgrade_downgrade_and_vector_indexes(pg_schema_url: str) -> None:
    state = migrate.init_database(pg_schema_url)[1]
    assert state.dialect == "postgresql" and state.at_head
    import_models()
    assert set(state.app_tables) >= _app_tables()
    assert _drift(pg_schema_url) == []
    engine = create_sync_engine(_sync_url(pg_schema_url))
    try:
        with engine.connect() as conn:
            schema = conn.execute(text("select current_schema()")).scalar_one()
            indexes = {
                row[0]: row[1]
                for row in conn.execute(
                    text("select indexname, indexdef from pg_indexes where schemaname = :s"), {"s": schema}
                )
            }
            assert "USING hnsw (embedding vector_cosine_ops)" in indexes["ixm_memory_records_embedding_hnsw"]
            assert "ixm_document_chunks_embedding_hnsw" in indexes
            assert any(n.startswith("uq_") or "key" in n for n in indexes)  # unique constraints exist
            columns = {c["name"]: c for c in inspect(conn).get_columns("memory_records")}
            assert str(columns["embedding"]["type"]).upper().startswith("VECTOR")
    finally:
        engine.dispose()
    down = migrate.downgrade(pg_schema_url, "base")
    assert down.current is None and down.app_tables == []
    assert migrate.upgrade(pg_schema_url).at_head  # and back up again


@pytest.mark.postgres
async def test_langgraph_postgres_checkpointer_opens_and_sets_up(pg_schema_url: str, tmp_path: Path) -> None:
    from langgraph.checkpoint.base import empty_checkpoint

    from app.orchestrator.checkpoint import CheckpointerHandle, checkpoint_kind

    settings = Settings(_env_file=None, env="development", database_url=pg_schema_url, local_dir=tmp_path)
    assert checkpoint_kind(settings) == "postgres"
    handle = CheckpointerHandle(settings)
    saver = await handle.open()
    try:
        config = {"configurable": {"thread_id": "turn_pg_1", "checkpoint_ns": ""}}
        checkpoint = empty_checkpoint()
        saved = await saver.aput(config, checkpoint, {"source": "input", "step": -1}, {})
        loaded = await saver.aget_tuple(saved)
        assert loaded is not None and loaded.checkpoint["id"] == checkpoint["id"]
    finally:
        await handle.close()
    admin = _admin_conninfo(pg_schema_url.split("?", 1)[0])
    schema = pg_schema_url.rsplit("search_path%3D", 1)[1].split("%2C", 1)[0]
    with psycopg.connect(admin) as conn:
        tables = {
            r[0] for r in conn.execute("select tablename from pg_tables where schemaname = %s", (schema,))
        }
    assert {"checkpoints", "checkpoint_blobs", "checkpoint_writes"} <= tables
