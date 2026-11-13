"""Checkpointer for the supervisor graph: memory in tests, a SQLite file next to the default
development database, the PostgreSQL saver when the database URL is PostgreSQL.

Checkpoints hold turn state (the owner's words, tool results), so persistent savers encrypt it
with the server's data key (AES-256-GCM) before it reaches the database.
"""

from __future__ import annotations

import logging
import os
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from langgraph.checkpoint.base import BaseCheckpointSaver
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.checkpoint.serde.encrypted import EncryptedSerializer
from sqlalchemy.engine import make_url

from app.core.settings import Settings
from app.db.session import normalise_database_url

log = logging.getLogger(__name__)

_NONCE = 12
_CIPHER_NAME = "zoro-aesgcm"


class DataKeyCipher:
    """`CipherProtocol` for LangGraph's `EncryptedSerializer`, using the kernel data key."""

    def __init__(self, key: bytes) -> None:
        self._aead = AESGCM(key)

    def encrypt(self, plaintext: bytes) -> tuple[str, bytes]:
        nonce = os.urandom(_NONCE)
        return _CIPHER_NAME, nonce + self._aead.encrypt(nonce, plaintext, b"zoro-checkpoint")

    def decrypt(self, ciphername: str, ciphertext: bytes) -> bytes:
        if ciphername != _CIPHER_NAME:
            raise ValueError(f"unsupported checkpoint cipher: {ciphername}")
        return self._aead.decrypt(ciphertext[:_NONCE], ciphertext[_NONCE:], b"zoro-checkpoint")


def checkpoint_kind(settings: Settings) -> str:
    """ "memory" | "sqlite" | "postgres" for these settings."""
    if settings.env == "test":
        return "memory"
    url = make_url(normalise_database_url(settings.database_url))
    if url.get_backend_name() == "postgresql":
        return "postgres"
    if not url.database or url.database == ":memory:":
        return "memory"
    return "sqlite"


def sqlite_checkpoint_path(settings: Settings) -> Path:
    """`<database file>.checkpoints` beside the application database."""
    database = make_url(normalise_database_url(settings.database_url)).database or "zoro.db"
    path = Path(database).expanduser()
    return path.with_name(path.name + ".checkpoints")


def postgres_conninfo(settings: Settings) -> str:
    """libpq connection string from the SQLAlchemy URL (driver suffix removed)."""
    url = make_url(normalise_database_url(settings.database_url)).set(drivername="postgresql")
    return url.render_as_string(hide_password=False)


class CheckpointerHandle:
    """Opens the right saver at startup and closes it at shutdown."""

    def __init__(self, settings: Settings, *, kind: str | None = None) -> None:
        self._settings = settings
        self.kind = kind or checkpoint_kind(settings)
        self._stack = AsyncExitStack()
        self.saver: BaseCheckpointSaver[Any] | None = None

    async def open(self) -> BaseCheckpointSaver[Any]:
        if self.saver is not None:
            return self.saver
        if self.kind == "memory":
            self.saver = InMemorySaver()
            return self.saver
        serde = EncryptedSerializer(DataKeyCipher(self._settings.data_key_bytes()))
        if self.kind == "sqlite":
            import aiosqlite
            from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver

            path = sqlite_checkpoint_path(self._settings)
            path.parent.mkdir(parents=True, exist_ok=True)
            conn = await self._stack.enter_async_context(aiosqlite.connect(str(path)))
            sqlite_saver = AsyncSqliteSaver(conn, serde=serde)
            await sqlite_saver.setup()
            self.saver = sqlite_saver
        elif self.kind == "postgres":
            from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

            postgres_saver = await self._stack.enter_async_context(
                AsyncPostgresSaver.from_conn_string(postgres_conninfo(self._settings), serde=serde)
            )
            await postgres_saver.setup()
            self.saver = postgres_saver
        else:
            raise ValueError(f"unknown checkpointer kind: {self.kind}")
        log.info("checkpointer ready", extra={"kind": self.kind})
        return self.saver

    async def close(self) -> None:
        await self._stack.aclose()
        self.saver = None

    async def delete_threads(self, thread_ids: list[str]) -> None:
        """Drop the checkpoints of finished or deleted turns (thread id = turn id)."""
        if self.saver is None:
            return
        for thread_id in thread_ids:
            try:
                await self.saver.adelete_thread(thread_id)
            except Exception as exc:  # cleanup must never fail a request
                log.warning("checkpoint cleanup failed", extra={"error_type": type(exc).__name__})
