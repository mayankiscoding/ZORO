"""Alembic environment: async engine, the app's own model discovery and URL handling.

The URL comes from (in order) ``-x url=...``, the ``sqlalchemy.url`` set by `app.cli migrate`, or
``ZORO_DATABASE_URL`` through the app settings. Every package's ``models.py`` is imported through
`app.db.discovery.import_models`, so ``Base.metadata`` knows every table without a shared list.
"""

from __future__ import annotations

import asyncio
from logging.config import fileConfig
from typing import Any

from alembic import context
from sqlalchemy import pool, text
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from app.db.base import Base
from app.db.discovery import import_models
from app.db.session import normalise_database_url

config = context.config
if config.config_file_name is not None and config.attributes.get("configure_logger", True):
    fileConfig(config.config_file_name, disable_existing_loggers=False)

import_models()
target_metadata = Base.metadata


def _database_url() -> str:
    x_args = context.get_x_argument(as_dictionary=True)
    url = x_args.get("url") or config.get_main_option("sqlalchemy.url")
    if not url:
        from app.core.settings import get_settings

        url = get_settings().database_url
    return normalise_database_url(url)


def _include_object(obj: Any, name: str | None, type_: str, reflected: bool, compare_to: Any) -> bool:
    """Leave out what the models do not declare on purpose: LangGraph's checkpoint tables (created
    by its PostgreSQL saver's setup()) and the hand-written ``ixm_*`` indexes of revision 0002."""
    if not reflected or compare_to is not None or name is None:
        return True
    if type_ == "table" and name.startswith("checkpoint"):
        return False
    return not (type_ == "index" and name.startswith("ixm_"))


def _configure(connection: Connection | None = None, url: str | None = None) -> None:
    is_sqlite = (url or "").startswith("sqlite") or (
        connection is not None and connection.dialect.name == "sqlite"
    )
    context.configure(
        connection=connection,
        url=url,
        target_metadata=target_metadata,
        compare_type=True,
        include_object=_include_object,
        render_as_batch=is_sqlite,  # SQLite needs batch mode for ALTER
        literal_binds=connection is None,
        dialect_opts={"paramstyle": "named"} if connection is None else {},
    )


def run_migrations_offline() -> None:
    _configure(url=_database_url())
    with context.begin_transaction():
        context.run_migrations()


def _run_sync(connection: Connection) -> None:
    if connection.dialect.name == "postgresql":
        connection.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
    _configure(connection=connection)
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    url = _database_url()
    section = dict(config.get_section(config.config_ini_section, {}))
    section["sqlalchemy.url"] = url
    connectable = async_engine_from_config(section, prefix="sqlalchemy.", poolclass=pool.NullPool)
    async with connectable.connect() as connection:
        await connection.run_sync(_run_sync)
        await connection.commit()
    await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    existing = config.attributes.get("connection")
    if existing is not None:  # called from code with an open sync connection
        _run_sync(existing)
    else:
        asyncio.run(run_migrations_online())
