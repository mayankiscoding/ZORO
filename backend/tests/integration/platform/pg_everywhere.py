"""Pytest plugin: run the WHOLE suite on PostgreSQL + pgvector, one fresh schema per test.

    ZORO_TEST_DATABASE_URL=$(../scripts/dev_db.sh url) \\
        uv run --no-sync pytest -p tests.integration.platform.pg_everywhere

Tests run in a dedicated database ``<name>_pytest`` next to the one in the URL (created once, with
the ``vector`` extension), never in the development database itself: a table that already exists in
``public`` would otherwise be found through the search path and shared between tests. Every test that
uses the shared `settings` fixture gets its own schema there (``search_path`` set through the libpq
``options`` parameter, ``public`` kept second for the ``vector`` type), so tests stay isolated
exactly as they are with one SQLite file each. The schema is dropped afterwards. Without
``ZORO_TEST_DATABASE_URL`` this plugin does nothing; tests with "sqlite" in their name keep SQLite.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import Iterator
from urllib.parse import quote

import psycopg
import pytest
from sqlalchemy.engine import make_url

from app.db.session import normalise_database_url

ENV_URL = "ZORO_TEST_DATABASE_URL"
TEST_DB_SUFFIX = "_pytest"


def _admin_conninfo(url: str) -> str:
    return (
        make_url(normalise_database_url(url))
        .set(drivername="postgresql")
        .render_as_string(hide_password=False)
    )


def schema_url(url: str, schema: str) -> str:
    base = normalise_database_url(url)
    separator = "&" if "?" in base else "?"
    return f"{base}{separator}options={quote(f'-csearch_path={schema},public')}"


def isolated_database_url(url: str) -> str:
    """URL of the dedicated test database, created with pgvector when missing."""
    parsed = make_url(normalise_database_url(url))
    name = parsed.database or "zoro"
    if name.endswith(TEST_DB_SUFFIX):
        return parsed.render_as_string(hide_password=False)
    target = f"{name}{TEST_DB_SUFFIX}"
    with psycopg.connect(_admin_conninfo(url), autocommit=True) as conn:
        exists = conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (target,)).fetchone()
        if not exists:
            conn.execute(f'CREATE DATABASE "{target}"')
    isolated = parsed.set(database=target).render_as_string(hide_password=False)
    with psycopg.connect(_admin_conninfo(isolated), autocommit=True) as conn:
        conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
    return isolated


@pytest.fixture(scope="session")
def _isolated_pg_url() -> str | None:
    url = os.environ.get(ENV_URL)
    return isolated_database_url(url) if url else None


@pytest.fixture(autouse=True)
def _postgres_schema_per_test(request: pytest.FixtureRequest, _isolated_pg_url: str | None) -> Iterator[None]:
    url = _isolated_pg_url
    # Tests about SQLite behaviour itself keep their SQLite file.
    if not url or "settings" not in request.fixturenames or "sqlite" in request.node.name.lower():
        yield
        return
    settings = request.getfixturevalue("settings")
    schema = f"t_{uuid.uuid4().hex[:16]}"
    admin = _admin_conninfo(url)
    with psycopg.connect(admin, autocommit=True) as conn:
        conn.execute(f'CREATE SCHEMA "{schema}"')
    settings.database_url = schema_url(url, schema)
    try:
        yield
    finally:
        with psycopg.connect(admin, autocommit=True) as conn:
            conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
