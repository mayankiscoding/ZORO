"""Schema management on top of Alembic (``backend/migrations``), for SQLite and PostgreSQL.

- `upgrade` / `downgrade` run Alembic against the configured database.
- `init_database` is the first-run path: an empty database is migrated to head; a SQLite
  development database (or one created earlier by ``create_all``) gets its missing tables and is
  stamped at head, so later migrations apply cleanly.

These functions are synchronous and start their own event loop where needed: Alembic's env.py
runs the async engine with ``asyncio.run``, so they must not be called from inside a running loop.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import inspect
from sqlalchemy.engine import Connection

from app.db.base import Base
from app.db.discovery import import_models
from app.db.session import create_engine, init_db, normalise_database_url

BACKEND_DIR = Path(__file__).resolve().parents[2]
ALEMBIC_INI = BACKEND_DIR / "alembic.ini"
VERSION_TABLE = "alembic_version"


@dataclass
class SchemaState:
    dialect: str
    current: str | None
    head: str
    tables: list[str] = field(default_factory=list)

    @property
    def app_tables(self) -> list[str]:
        known = set(Base.metadata.tables)
        return sorted(t for t in self.tables if t in known)

    @property
    def at_head(self) -> bool:
        return self.current == self.head


def alembic_config(url: str) -> Config:
    cfg = Config(str(ALEMBIC_INI))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    # ConfigParser interpolation: a literal % in a URL (encoded password) must be doubled.
    cfg.set_main_option("sqlalchemy.url", normalise_database_url(url).replace("%", "%%"))
    cfg.attributes["configure_logger"] = False
    return cfg


def head_revision() -> str:
    head = ScriptDirectory.from_config(alembic_config("sqlite://")).get_current_head()
    if head is None:
        raise RuntimeError("no migrations found in backend/migrations/versions")
    return head


def _read_state(connection: Connection) -> tuple[str | None, list[str]]:
    current = MigrationContext.configure(connection).get_current_revision()
    return current, sorted(inspect(connection).get_table_names())


async def _state_async(url: str) -> tuple[str, str | None, list[str]]:
    engine = create_engine(url)
    try:
        async with engine.connect() as conn:
            current, tables = await conn.run_sync(_read_state)
        return engine.dialect.name, current, tables
    finally:
        await engine.dispose()


def schema_state(url: str) -> SchemaState:
    import_models()
    dialect, current, tables = asyncio.run(_state_async(url))
    return SchemaState(dialect=dialect, current=current, head=head_revision(), tables=tables)


class SchemaNotManaged(RuntimeError):
    """The database has application tables but no Alembic version: adopt it with `init-db`."""


def upgrade(url: str, revision: str = "head") -> SchemaState:
    state = schema_state(url)
    if state.current is None and state.app_tables:
        raise SchemaNotManaged(
            f"{len(state.app_tables)} tables exist but the database is not under migration control; "
            "run `python -m app.cli init-db` once to adopt it (creates missing tables, stamps head)"
        )
    command.upgrade(alembic_config(url), revision)
    return schema_state(url)


def downgrade(url: str, revision: str) -> SchemaState:
    command.downgrade(alembic_config(url), revision)
    return schema_state(url)


def stamp(url: str, revision: str = "head") -> None:
    command.stamp(alembic_config(url), revision)


def init_database(url: str) -> tuple[str, SchemaState]:
    """Bring any database to head. Returns (what was done, resulting state)."""
    state = schema_state(url)
    if state.current is not None:
        return ("migrated" if not state.at_head else "up_to_date", upgrade(url))
    if not state.app_tables and state.dialect == "postgresql":
        return "migrated", upgrade(url)

    async def _create() -> None:
        engine = create_engine(url)
        try:
            await init_db(engine)
        finally:
            await engine.dispose()

    asyncio.run(_create())  # SQLite development, or adopting a database made by create_all
    stamp(url)
    return ("adopted" if state.app_tables else "created"), schema_state(url)
