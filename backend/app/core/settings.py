"""Runtime settings from environment variables (design spec section 11).

Development and test run with no configuration at all: signing and data keys are generated
locally (persisted under `.local/` in development, in memory in tests) and never live in source.
Production refuses to start without `ZORO_SECRET_KEY` and `ZORO_DATA_KEY`.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import secrets
from functools import lru_cache
from pathlib import Path
from typing import Any, Literal

from pydantic import PrivateAttr, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.core.types import PrivacyMode

_REPO_ROOT = Path(__file__).resolve().parents[3]
_ENV_ALIASES = {"dev": "development", "prod": "production", "testing": "test"}
_MIN_SECRET_LENGTH = 32


def _decode_data_key(value: str) -> bytes:
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("ZORO_DATA_KEY must be base64") from exc
    if len(raw) != 32:
        raise ValueError("ZORO_DATA_KEY must decode to exactly 32 bytes")
    return raw


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ZORO_",
        env_file=(".env", "../.env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    env: Literal["development", "test", "production"] = "development"
    database_url: str = "sqlite+aiosqlite:///./.local/zoro.db"
    secret_key: SecretStr | None = None
    data_key: SecretStr | None = None
    config_dir: Path = _REPO_ROOT / "config"
    redis_url: str | None = None
    object_store: Literal["fs", "minio"] = "fs"
    object_dir: Path = Path("./.local/objects")
    minio_endpoint: str | None = None
    minio_access_key: SecretStr | None = None
    minio_secret_key: SecretStr | None = None
    minio_bucket: str = "zoro"
    minio_secure: bool = False
    public_base_url: str = "http://127.0.0.1:8000"
    default_privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE
    conversation_retention_days: int = 30
    access_token_ttl_seconds: int = 900
    server_name: str = "ZORO"
    log_level: str = "INFO"
    local_dir: Path = Path("./.local")
    auto_create_schema: bool | None = None  # default: true outside production

    _generated: dict[str, str] = PrivateAttr(default_factory=dict)

    @field_validator("env", mode="before")
    @classmethod
    def _normalise_env(cls, value: Any) -> Any:
        if isinstance(value, str):
            lowered = value.strip().lower()
            return _ENV_ALIASES.get(lowered, lowered)
        return value

    @field_validator("access_token_ttl_seconds")
    @classmethod
    def _ttl_bounds(cls, value: int) -> int:
        if not 60 <= value <= 3600:
            raise ValueError("ZORO_ACCESS_TOKEN_TTL_SECONDS must be between 60 and 3600")
        return value

    @model_validator(mode="after")
    def _check_keys(self) -> Settings:
        if self.data_key is not None:
            _decode_data_key(self.data_key.get_secret_value())
        if self.env == "production":
            missing = [
                name
                for name, value in (("ZORO_SECRET_KEY", self.secret_key), ("ZORO_DATA_KEY", self.data_key))
                if value is None or not value.get_secret_value()
            ]
            if missing:
                raise ValueError(
                    f"production needs {' and '.join(missing)} (run: python -m app.cli gen-keys)"
                )
            if self.secret_key is not None and len(self.secret_key.get_secret_value()) < _MIN_SECRET_LENGTH:
                raise ValueError(f"ZORO_SECRET_KEY must be at least {_MIN_SECRET_LENGTH} characters")
        return self

    # ------------------------------------------------------------ derived

    @property
    def is_production(self) -> bool:
        return self.env == "production"

    @property
    def is_sqlite(self) -> bool:
        return self.database_url.startswith("sqlite")

    @property
    def create_schema_on_start(self) -> bool:
        if self.auto_create_schema is not None:
            return self.auto_create_schema
        return not self.is_production

    def signing_key(self) -> bytes:
        """Key for session JWTs (HS256) and for peppering one-time codes."""
        if self.secret_key is not None and self.secret_key.get_secret_value():
            return self.secret_key.get_secret_value().encode("utf-8")
        return self._local_key("secret_key").encode("utf-8")

    def data_key_bytes(self) -> bytes:
        """32-byte AES-256-GCM key for `FieldCipher`."""
        if self.data_key is not None and self.data_key.get_secret_value():
            return _decode_data_key(self.data_key.get_secret_value())
        return _decode_data_key(self._local_key("data_key"))

    # ------------------------------------------------------------ local key material

    def _local_key(self, name: str) -> str:
        if self.is_production:  # unreachable after validation; kept as a second lock
            raise RuntimeError("production keys must come from the environment")
        if name not in self._generated:
            if self.env == "development":
                self._generated.update(_load_or_create_dev_keys(self.local_dir / "dev-keys.json"))
            else:
                self._generated.update(_new_key_material())
        return self._generated[name]


def _new_key_material() -> dict[str, str]:
    return {
        "secret_key": secrets.token_urlsafe(48),
        "data_key": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
    }


def _load_or_create_dev_keys(path: Path) -> dict[str, str]:
    """Development only: keep generated keys in a git-ignored, owner-readable file."""
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and {"secret_key", "data_key"} <= set(data):
                _decode_data_key(str(data["data_key"]))
                return {"secret_key": str(data["secret_key"]), "data_key": str(data["data_key"])}
        except (OSError, ValueError):
            pass
    material = _new_key_material()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(material, handle)
    return material


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
