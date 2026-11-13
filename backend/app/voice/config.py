"""Loader for config/voices.yaml (reloads when the file changes)."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field

from app.core.types import DataClass

log = logging.getLogger(__name__)

Lang = Literal["en", "hi", "hinglish"]
EngineId = Literal["gemini_tts", "google_chirp", "elevenlabs"]


class _Cfg(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class VoiceEntry(_Cfg):
    id: str
    name: str
    gender: Literal["female", "male", "neutral"]
    languages: tuple[Lang, ...] = ("en", "hi", "hinglish")


class LiveConfig(_Cfg):
    provider: str = "gemini"
    ws_url: str
    token_uses: int = Field(default=1, ge=1, le=1)
    session_ttl_seconds: int = Field(default=600, ge=30, le=1800)
    new_session_ttl_seconds: int = Field(default=60, ge=10, le=300)
    input_sample_rate: int = 16000
    output_sample_rate: int = 24000
    tool_name: str = "ask_zoro"


class EngineConfig(_Cfg):
    provider: str | None = None  # models.yaml provider (base URL + key), for Gemini
    base_url: str | None = None
    key_env: str | None = None
    model_id: str | None = None
    output_format: str | None = None
    sample_rate: int = 24000
    locales: dict[str, str] = Field(default_factory=dict)
    voices: tuple[VoiceEntry, ...] = ()
    allowed_data_classes: frozenset[DataClass] = frozenset({DataClass.PUBLIC, DataClass.PERSONAL})


class TTSConfig(_Cfg):
    order: tuple[EngineId, ...] = ("gemini_tts", "google_chirp", "elevenlabs")
    engines: dict[EngineId, EngineConfig]


class VoicesConfig(_Cfg):
    version: int = 1
    live: LiveConfig
    tts: TTSConfig


def load_voices(path: Path) -> VoicesConfig:
    with path.open("r", encoding="utf-8") as fh:
        raw: Any = yaml.safe_load(fh) or {}
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: top level must be a mapping")
    return VoicesConfig.model_validate(raw)


class VoicesStore:
    """Reads voices.yaml; keeps the last good version when an edit is broken."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._stamp: tuple[int, int] | None = None
        self._config = self._read()

    def _stat(self) -> tuple[int, int]:
        st = self.path.stat()
        return (st.st_mtime_ns, st.st_size)

    def _read(self) -> VoicesConfig:
        stamp = self._stat()
        cfg = load_voices(self.path)
        self._stamp = stamp
        return cfg

    def current(self) -> VoicesConfig:
        try:
            changed = self._stat() != self._stamp
        except OSError:
            return self._config
        if changed:
            try:
                self._config = self._read()
            except (OSError, ValueError, yaml.YAMLError) as exc:
                log.error("voices config reload failed, keeping the last good version: %s", exc)
                self._stamp = self._stat()
        return self._config
