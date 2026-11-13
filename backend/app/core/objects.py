"""Object storage for documents, exports and media: filesystem by default, MinIO when configured.

Keys are slash-separated relative paths ("documents/2026/abc.pdf"). The MinIO implementation is
imported lazily so the `minio` package stays optional.
"""

from __future__ import annotations

import asyncio
import io
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Protocol, runtime_checkable

from app.core.errors import BadRequest, ConfigError, NotFound

if TYPE_CHECKING:
    from app.core.settings import Settings

_KEY_PART = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@=+-]*$")


@dataclass(frozen=True)
class ObjectInfo:
    key: str
    size: int
    content_type: str | None = None


class ObjectNotFound(NotFound):
    code = "object_not_found"
    default_message = "The stored file does not exist."


def validate_key(key: str) -> str:
    """Reject absolute paths, traversal and odd characters. Returns the normalised key."""
    if not key or len(key) > 512 or any(not _KEY_PART.match(part) for part in key.split("/")):
        raise BadRequest("Object key is not valid.", code="object_key_invalid")
    return key


@runtime_checkable
class ObjectStore(Protocol):
    async def put(self, key: str, data: bytes, *, content_type: str | None = None) -> ObjectInfo: ...
    async def get(self, key: str) -> bytes: ...
    async def exists(self, key: str) -> bool: ...
    async def delete(self, key: str) -> bool: ...
    async def list(self, prefix: str = "") -> list[ObjectInfo]: ...


class FilesystemObjectStore:
    def __init__(self, root: Path) -> None:
        self._root = Path(root).expanduser().resolve()

    @property
    def root(self) -> Path:
        return self._root

    def _path(self, key: str) -> Path:
        path = (self._root / validate_key(key)).resolve()
        if not path.is_relative_to(self._root):
            raise BadRequest("Object key is not valid.", code="object_key_invalid")
        return path

    def _put(self, key: str, data: bytes, content_type: str | None) -> ObjectInfo:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
            os.replace(tmp, path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise
        return ObjectInfo(key=validate_key(key), size=len(data), content_type=content_type)

    def _get(self, key: str) -> bytes:
        path = self._path(key)
        if not path.is_file():
            raise ObjectNotFound()
        return path.read_bytes()

    def _delete(self, key: str) -> bool:
        path = self._path(key)
        if not path.is_file():
            return False
        path.unlink()
        return True

    def _list(self, prefix: str) -> list[ObjectInfo]:
        if not self._root.is_dir():
            return []
        found: list[ObjectInfo] = []
        for path in sorted(self._root.rglob("*")):
            if not path.is_file() or path.name.startswith(".tmp-"):
                continue
            key = path.relative_to(self._root).as_posix()
            if key.startswith(prefix):
                found.append(ObjectInfo(key=key, size=path.stat().st_size))
        return found

    async def put(self, key: str, data: bytes, *, content_type: str | None = None) -> ObjectInfo:
        return await asyncio.to_thread(self._put, key, data, content_type)

    async def get(self, key: str) -> bytes:
        return await asyncio.to_thread(self._get, key)

    async def exists(self, key: str) -> bool:
        return await asyncio.to_thread(lambda: self._path(key).is_file())

    async def delete(self, key: str) -> bool:
        return await asyncio.to_thread(self._delete, key)

    async def list(self, prefix: str = "") -> list[ObjectInfo]:
        return await asyncio.to_thread(self._list, prefix)


class MinioObjectStore:
    """S3-compatible store through the optional `minio` package (blocking client run in threads)."""

    def __init__(self, *, endpoint: str, access_key: str, secret_key: str, bucket: str, secure: bool) -> None:
        try:
            from minio import Minio  # type: ignore[import-not-found, unused-ignore]
        except ImportError as exc:
            raise ConfigError(
                "ZORO_OBJECT_STORE=minio needs the optional 'objectstore' dependency (minio).",
                code="object_store_unavailable",
            ) from exc
        self._client: Any = Minio(endpoint, access_key=access_key, secret_key=secret_key, secure=secure)
        self._bucket = bucket
        self._bucket_ready = False

    def _ensure_bucket(self) -> None:
        if not self._bucket_ready:
            if not self._client.bucket_exists(self._bucket):
                self._client.make_bucket(self._bucket)
            self._bucket_ready = True

    def _is_missing(self, exc: Exception) -> bool:
        return getattr(exc, "code", "") in {"NoSuchKey", "NoSuchObject", "NoSuchBucket"}

    def _put(self, key: str, data: bytes, content_type: str | None) -> ObjectInfo:
        self._ensure_bucket()
        self._client.put_object(
            self._bucket,
            key,
            io.BytesIO(data),
            length=len(data),
            content_type=content_type or "application/octet-stream",
        )
        return ObjectInfo(key=key, size=len(data), content_type=content_type)

    def _get(self, key: str) -> bytes:
        try:
            response = self._client.get_object(self._bucket, key)
        except Exception as exc:
            if self._is_missing(exc):
                raise ObjectNotFound() from exc
            raise
        try:
            return bytes(response.read())
        finally:
            response.close()
            response.release_conn()

    def _exists(self, key: str) -> bool:
        try:
            self._client.stat_object(self._bucket, key)
        except Exception as exc:
            if self._is_missing(exc):
                return False
            raise
        return True

    def _delete(self, key: str) -> bool:
        if not self._exists(key):
            return False
        self._client.remove_object(self._bucket, key)
        return True

    def _list(self, prefix: str) -> list[ObjectInfo]:
        self._ensure_bucket()
        return [
            ObjectInfo(key=str(item.object_name), size=int(item.size or 0))
            for item in self._client.list_objects(self._bucket, prefix=prefix or None, recursive=True)
        ]

    async def put(self, key: str, data: bytes, *, content_type: str | None = None) -> ObjectInfo:
        return await asyncio.to_thread(self._put, validate_key(key), data, content_type)

    async def get(self, key: str) -> bytes:
        return await asyncio.to_thread(self._get, validate_key(key))

    async def exists(self, key: str) -> bool:
        return await asyncio.to_thread(self._exists, validate_key(key))

    async def delete(self, key: str) -> bool:
        return await asyncio.to_thread(self._delete, validate_key(key))

    async def list(self, prefix: str = "") -> list[ObjectInfo]:
        return await asyncio.to_thread(self._list, prefix)


def build_object_store(settings: Settings) -> ObjectStore:
    if settings.object_store == "minio":
        if not (settings.minio_endpoint and settings.minio_access_key and settings.minio_secret_key):
            raise ConfigError(
                "ZORO_OBJECT_STORE=minio needs ZORO_MINIO_ENDPOINT, ZORO_MINIO_ACCESS_KEY and "
                "ZORO_MINIO_SECRET_KEY.",
                code="object_store_unavailable",
            )
        return MinioObjectStore(
            endpoint=settings.minio_endpoint,
            access_key=settings.minio_access_key.get_secret_value(),
            secret_key=settings.minio_secret_key.get_secret_value(),
            bucket=settings.minio_bucket,
            secure=settings.minio_secure,
        )
    return FilesystemObjectStore(settings.object_dir)
