"""Engine, portable column types, vector search, object store."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pytest
from sqlalchemy import String, select, text
from sqlalchemy.dialects import postgresql, sqlite
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.schema import CreateTable

from app.core.errors import BadRequest, ConfigError
from app.core.objects import FilesystemObjectStore, ObjectNotFound, ObjectStore, build_object_store
from app.core.settings import Settings
from app.db import Base, Database, EmbeddingType, JSONType, UTCDateTime, cosine_similarity, vector_search
from app.db.session import create_engine, init_db, normalise_database_url
from app.db.vector import pgvector_statement
from app.plugins import PluginRegistry


class KernelTestDoc(Base):
    __tablename__ = "kernel_test_docs"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    owner: Mapped[str] = mapped_column(String(32))
    meta: Mapped[Any] = mapped_column(JSONType, default=dict)
    embedding: Mapped[list[float] | None] = mapped_column(EmbeddingType(3), nullable=True)
    seen_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


async def _seed(db: AsyncSession) -> None:
    db.add_all(
        [
            KernelTestDoc(id="east", owner="me", embedding=[1.0, 0.0, 0.0], meta={"tags": ["a"], "n": 1}),
            KernelTestDoc(id="north_east", owner="me", embedding=[1.0, 1.0, 0.0]),
            KernelTestDoc(id="north", owner="me", embedding=[0.0, 1.0, 0.0]),
            KernelTestDoc(id="west", owner="other", embedding=[-1.0, 0.0, 0.0]),
            KernelTestDoc(id="no_vector", owner="me", embedding=None),
        ]
    )
    await db.commit()


# ---------------------------------------------------------------- types


def test_column_types_compile_per_dialect() -> None:
    pg = str(CreateTable(KernelTestDoc.__table__).compile(dialect=postgresql.dialect()))  # type: ignore[arg-type]
    lite = str(CreateTable(KernelTestDoc.__table__).compile(dialect=sqlite.dialect()))  # type: ignore[arg-type]
    assert "meta JSONB" in pg and "embedding VECTOR(3)" in pg
    assert "meta JSON" in lite and "embedding JSON" in lite
    assert "TIMESTAMP WITH TIME ZONE" in pg
    with pytest.raises(ValueError):
        EmbeddingType(0)


async def test_json_embedding_and_datetime_round_trip(db: AsyncSession) -> None:
    await _seed(db)
    ist = timezone(timedelta(hours=5, minutes=30))
    row = await db.get(KernelTestDoc, "east")
    assert row is not None
    assert row.meta == {"tags": ["a"], "n": 1}
    assert row.embedding == [1.0, 0.0, 0.0]
    row.seen_at = datetime(2026, 11, 13, 10, 0, tzinfo=ist)
    row.meta = {**row.meta, "नाम": "ज़ोरो"}
    await db.commit()
    db.expire_all()
    again = (await db.execute(select(KernelTestDoc).where(KernelTestDoc.id == "east"))).scalar_one()
    assert again.seen_at == datetime(2026, 11, 13, 4, 30, tzinfo=UTC) and again.seen_at.tzinfo is not None
    assert again.meta["नाम"] == "ज़ोरो"

    db.add(KernelTestDoc(id="bad_dim", owner="me", embedding=[1.0, 2.0]))
    with pytest.raises(Exception, match="expects 3"):
        await db.commit()
    await db.rollback()
    db.add(KernelTestDoc(id="naive", owner="me", seen_at=datetime(2026, 1, 1)))
    with pytest.raises(Exception, match="naive datetime"):
        await db.commit()
    await db.rollback()


# ---------------------------------------------------------------- vector search


def test_cosine_similarity() -> None:
    assert cosine_similarity([1, 0], [1, 0]) == pytest.approx(1.0)
    assert cosine_similarity([1, 0], [0, 1]) == pytest.approx(0.0)
    assert cosine_similarity([1, 0], [-1, 0]) == pytest.approx(-1.0)
    assert cosine_similarity([0, 0], [1, 0]) == 0.0
    with pytest.raises(ValueError):
        cosine_similarity([1, 0], [1, 0, 0])


async def _check_vector_search(db: AsyncSession) -> None:
    await _seed(db)
    hits = await vector_search(db, KernelTestDoc, KernelTestDoc.embedding, [1.0, 0.1, 0.0], limit=10)
    assert [doc.id for doc, _ in hits] == ["east", "north_east", "north", "west"]  # NULL embedding skipped
    scores = [score for _, score in hits]
    assert scores == sorted(scores, reverse=True)
    assert scores[0] == pytest.approx(0.995, abs=1e-3) and scores[-1] == pytest.approx(-0.995, abs=1e-3)

    top = await vector_search(db, KernelTestDoc, KernelTestDoc.embedding, [1.0, 0.1, 0.0], limit=2)
    assert [doc.id for doc, _ in top] == ["east", "north_east"]
    mine = await vector_search(
        db, KernelTestDoc, KernelTestDoc.embedding, [-1.0, 0.0, 0.0], where=[KernelTestDoc.owner == "me"]
    )
    assert "west" not in [doc.id for doc, _ in mine]
    close = await vector_search(db, KernelTestDoc, KernelTestDoc.embedding, [1.0, 0.0, 0.0], min_score=0.7)
    assert [doc.id for doc, _ in close] == ["east", "north_east"]
    assert await vector_search(db, KernelTestDoc, KernelTestDoc.embedding, [1.0, 0.0, 0.0], limit=0) == []


def test_pgvector_statement_compiles_for_postgresql() -> None:
    statement = pgvector_statement(
        KernelTestDoc, KernelTestDoc.embedding, [1.0, 0.0, 0.0], limit=5, where=[KernelTestDoc.owner == "me"]
    )
    dialect = postgresql.dialect()
    compiled = statement.compile(dialect=dialect)
    sql = str(compiled).replace("\n", " ")
    assert " - (kernel_test_docs.embedding <=> %(embedding_1)s) AS score" in sql
    bind = compiled.binds["embedding_1"]
    assert isinstance(bind.type, EmbeddingType)  # the query vector goes through the pgvector type
    to_wire = bind.type.dialect_impl(dialect).bind_processor(dialect)
    assert to_wire is not None and to_wire([1.0, 0.0, 0.5]) == "[1.0,0.0,0.5]"
    from_wire = bind.type.dialect_impl(dialect).result_processor(dialect, None)
    assert from_wire is not None and from_wire("[1,2,3]") == [1.0, 2.0, 3.0]
    assert "kernel_test_docs.embedding IS NOT NULL AND kernel_test_docs.owner = " in sql
    assert "ORDER BY kernel_test_docs.embedding <=> " in sql and "LIMIT" in sql


async def test_vector_search_on_sqlite(db: AsyncSession) -> None:
    assert db.get_bind().dialect.name == "sqlite"
    await _check_vector_search(db)


@pytest.mark.postgres
async def test_vector_search_on_postgres(db: AsyncSession) -> None:
    assert db.get_bind().dialect.name == "postgresql"
    await db.execute(KernelTestDoc.__table__.delete())
    await db.commit()
    await _check_vector_search(db)


# ---------------------------------------------------------------- engine


def test_database_url_normalisation() -> None:
    assert normalise_database_url("postgres://u@h/db") == "postgresql+psycopg://u@h/db"
    assert normalise_database_url("postgresql://u@h/db") == "postgresql+psycopg://u@h/db"
    assert normalise_database_url("postgresql+psycopg://u@h/db") == "postgresql+psycopg://u@h/db"
    assert normalise_database_url("sqlite:///./x.db") == "sqlite+aiosqlite:///./x.db"
    engine = create_engine("postgresql://zoro@localhost:5432/zoro")  # no connection is opened
    assert engine.dialect.name == "postgresql" and engine.dialect.driver == "psycopg"
    with pytest.raises(ValueError, match="unsupported"):
        create_engine("mysql+aiomysql://u@h/db")


async def test_sqlite_engine_creates_its_directory_and_is_idempotent(tmp_path: Path) -> None:
    path = tmp_path / "nested" / "dir" / "zoro.db"
    database = Database.from_url(f"sqlite+aiosqlite:///{path}")
    try:
        tables = await database.init()
        assert await database.init() == tables  # create_all twice is fine
        assert {"devices", "audit_log", "kernel_tool_calls", "kernel_test_docs"} <= set(tables)
        assert path.exists() and await database.ping()
        async with database.session_factory() as session:
            assert (await session.execute(select(KernelTestDoc))).all() == []
            foreign_keys = (await session.execute(text("PRAGMA foreign_keys"))).scalar_one()
            assert foreign_keys == 1
    finally:
        await database.dispose()

    memory = create_engine("sqlite+aiosqlite:///:memory:")
    try:
        await init_db(memory)
        async with memory.connect() as one, memory.connect() as two:  # one shared in-memory database
            assert (await one.exec_driver_sql("SELECT count(*) FROM devices")).scalar_one() == 0
            assert (await two.exec_driver_sql("SELECT count(*) FROM devices")).scalar_one() == 0
    finally:
        await memory.dispose()


# ---------------------------------------------------------------- object store


async def test_filesystem_object_store(registry: PluginRegistry, tmp_path: Path) -> None:
    store = registry.service("objects")
    assert isinstance(store, FilesystemObjectStore) and isinstance(store, ObjectStore)
    info = await store.put("documents/2026/statement.pdf", b"%PDF-1.7 test", content_type="application/pdf")
    assert info.key == "documents/2026/statement.pdf" and info.size == 13
    await store.put("documents/2026/notes.txt", b"hello")
    await store.put("exports/all.json", b"{}")
    assert await store.get("documents/2026/statement.pdf") == b"%PDF-1.7 test"
    assert await store.exists("exports/all.json") and not await store.exists("exports/none.json")
    assert [o.key for o in await store.list("documents/")] == [
        "documents/2026/notes.txt",
        "documents/2026/statement.pdf",
    ]
    await store.put("exports/all.json", b'{"v":2}')  # overwrite is atomic
    assert await store.get("exports/all.json") == b'{"v":2}'
    assert await store.delete("exports/all.json") is True
    assert await store.delete("exports/all.json") is False
    with pytest.raises(ObjectNotFound):
        await store.get("exports/all.json")
    assert not [p for p in store.root.rglob(".tmp-*")]

    for key in ("../outside.txt", "/etc/passwd", "a/../../b", "", "a//b", "a/.hidden", "with space/x"):
        with pytest.raises(BadRequest):
            await store.put(key, b"x")
    assert not (store.root.parent / "outside.txt").exists()


def test_minio_store_needs_configuration_and_the_optional_package(tmp_path: Path) -> None:
    base = {"_env_file": None, "env": "test", "object_store": "minio"}
    with pytest.raises(ConfigError, match="ZORO_MINIO_ENDPOINT"):
        build_object_store(Settings(**base))  # type: ignore[arg-type]
    configured = Settings(
        **base,  # type: ignore[arg-type]
        minio_endpoint="127.0.0.1:9000",
        minio_access_key="test-access",
        minio_secret_key="test-secret",
    )
    try:
        import minio  # type: ignore[import-not-found, unused-ignore]  # noqa: F401
    except ImportError:
        with pytest.raises(ConfigError, match="objectstore"):
            build_object_store(configured)
    else:
        assert isinstance(build_object_store(configured), ObjectStore)
