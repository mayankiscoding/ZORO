"""Async engine and session factory for SQLite (aiosqlite) and PostgreSQL (psycopg 3)."""

from __future__ import annotations

import logging
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from sqlalchemy import event, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.discovery import import_models

log = logging.getLogger(__name__)

SessionFactory = async_sessionmaker[AsyncSession]


def normalise_database_url(url: str) -> str:
    """Accept the short driver-less forms and map them to the async drivers this project uses."""
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://") :]
    if url.startswith("postgresql://"):
        return "postgresql+psycopg://" + url[len("postgresql://") :]
    if url.startswith("sqlite://"):
        return "sqlite+aiosqlite://" + url[len("sqlite://") :]
    return url


def create_engine(url: str, *, echo: bool = False) -> AsyncEngine:
    """Build the async engine. SQLite gets foreign keys, WAL and a busy timeout; a file database's
    directory is created; an in-memory database shares one connection."""
    url = normalise_database_url(url)
    parsed = make_url(url)
    backend = parsed.get_backend_name()

    if backend == "sqlite":
        kwargs: dict[str, Any] = {"connect_args": {"timeout": 30}}
        database = parsed.database
        if not database or database == ":memory:":
            kwargs["poolclass"] = StaticPool
        else:
            Path(database).expanduser().parent.mkdir(parents=True, exist_ok=True)
        engine = create_async_engine(url, echo=echo, **kwargs)

        @event.listens_for(engine.sync_engine, "connect")
        def _sqlite_pragmas(dbapi_connection: Any, _record: Any) -> None:
            cursor = dbapi_connection.cursor()
            try:
                cursor.execute("PRAGMA foreign_keys=ON")
                cursor.execute("PRAGMA journal_mode=WAL")
                cursor.execute("PRAGMA busy_timeout=30000")
            finally:
                cursor.close()

        return engine

    if backend == "postgresql":
        return create_async_engine(url, echo=echo, pool_pre_ping=True)

    raise ValueError(f"unsupported database backend: {backend}")


def create_session_factory(engine: AsyncEngine) -> SessionFactory:
    return async_sessionmaker(engine, expire_on_commit=False, autoflush=False)


async def init_db(engine: AsyncEngine, *, packages: Sequence[str] | None = None) -> list[str]:
    """Discover models and create missing tables (development, tests, first run).

    On PostgreSQL the `vector` extension is enabled first when the role is allowed to. Returns the
    names of the tables known to the metadata.
    """
    import_models(packages)
    if engine.dialect.name == "postgresql":
        try:
            async with engine.begin() as conn:
                await conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
        except SQLAlchemyError:
            log.warning("could not enable the pgvector extension; embedding columns need it")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    return sorted(Base.metadata.tables)


async def drop_all(engine: AsyncEngine) -> None:
    """Tests only."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@dataclass
class Database:
    engine: AsyncEngine
    session_factory: SessionFactory

    @classmethod
    def from_url(cls, url: str, *, echo: bool = False) -> Database:
        engine = create_engine(url, echo=echo)
        return cls(engine=engine, session_factory=create_session_factory(engine))

    async def init(self, *, packages: Sequence[str] | None = None) -> list[str]:
        return await init_db(self.engine, packages=packages)

    async def ping(self) -> bool:
        try:
            async with self.engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
        except SQLAlchemyError:
            return False
        return True

    async def dispose(self) -> None:
        await self.engine.dispose()


def affected_rows(result: Any) -> int:
    """Row count of an UPDATE / DELETE result (typed helper around `CursorResult.rowcount`)."""
    return int(getattr(result, "rowcount", 0) or 0)
