"""Loader for config/models.yaml: providers, models, routes. Reloads when the file changes.

Model names, prices and URLs live only in the YAML file (CLAUDE.md rule 7).
"""

from __future__ import annotations

import logging
import os
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any, Literal, Protocol

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.core.types import DataClass, Locality, TaskClass

log = logging.getLogger(__name__)

ProviderKind = Literal["gemini", "openai_compatible"]
Capability = Literal["chat", "tools", "structured", "stream", "embed", "vision", "audio", "realtime", "tts"]


class _Cfg(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class ProviderEntry(_Cfg):
    id: str
    kind: ProviderKind
    base_url: str | None = None
    base_url_env: str | None = None  # overrides base_url when set (e.g. QWEN_BASE_URL, OLLAMA_BASE_URL)
    api_key_env: str | None = None
    keyless: bool = False  # local servers that need no key (only honoured for private localities)
    locality: Locality
    allowed_data_classes: frozenset[DataClass] = frozenset({DataClass.PUBLIC, DataClass.PERSONAL})
    enabled: bool = True  # hard switch; a provider also needs its key / URL to be usable
    max_tokens_field: str = "max_tokens"  # OpenAI-compatible: "max_tokens" or "max_completion_tokens"
    stream_usage: bool = True  # OpenAI-compatible: send stream_options.include_usage
    verified_on: str | None = None


class ModelEntry(_Cfg):
    id: str
    provider: str
    model_name: str
    context_window: int = Field(gt=0)
    price_in: Decimal = Decimal("0")  # USD per 1M input tokens
    price_out: Decimal = Decimal("0")  # USD per 1M output tokens
    capabilities: frozenset[Capability] = frozenset({"chat"})
    dims: int | None = None  # embedding models
    verified_on: str | None = None

    @field_validator("price_in", "price_out", mode="before")
    @classmethod
    def _exact_decimal(cls, value: Any) -> Decimal:
        # YAML may parse 0.75 as float; go through str so the Decimal is the written value.
        return Decimal(str(value))


class ModelsConfig(_Cfg):
    version: int = 1
    providers: tuple[ProviderEntry, ...]
    models: tuple[ModelEntry, ...]
    routes: Mapping[TaskClass, tuple[str, ...]]

    @model_validator(mode="after")
    def _check_refs(self) -> ModelsConfig:
        pids = [p.id for p in self.providers]
        mids = [m.id for m in self.models]
        if len(set(pids)) != len(pids) or len(set(mids)) != len(mids):
            raise ValueError("duplicate provider or model id")
        for m in self.models:
            if m.provider not in pids:
                raise ValueError(f"model {m.id}: unknown provider {m.provider}")
        for task, ids in self.routes.items():
            for mid in ids:
                if mid not in mids:
                    raise ValueError(f"route {task.value}: unknown model {mid}")
        return self

    def provider(self, pid: str) -> ProviderEntry:
        return next(p for p in self.providers if p.id == pid)

    def model(self, mid: str) -> ModelEntry:
        return next(m for m in self.models if m.id == mid)

    def route(self, task: TaskClass) -> tuple[str, ...]:
        return tuple(self.routes.get(task, ()))


@dataclass(frozen=True)
class ResolvedProvider:
    """A provider with its environment applied. `api_key` never leaves the process or the logs."""

    entry: ProviderEntry
    enabled: bool
    base_url: str | None
    api_key: str | None = None
    disabled_reason: str = ""

    def __repr__(self) -> str:  # keep the key out of reprs and tracebacks
        return f"ResolvedProvider(id={self.entry.id!r}, enabled={self.enabled}, base_url={self.base_url!r})"


_PRIVATE = frozenset({Locality.ON_DEVICE, Locality.LOCAL, Locality.PRIVATE_NETWORK})


def resolve_provider(entry: ProviderEntry, env: Mapping[str, str]) -> ResolvedProvider:
    base_url = (env.get(entry.base_url_env, "") if entry.base_url_env else "") or entry.base_url
    key = env.get(entry.api_key_env, "").strip() if entry.api_key_env else ""
    if not entry.enabled:
        return ResolvedProvider(entry, False, base_url, None, "disabled_in_config")
    if not base_url:
        return ResolvedProvider(entry, False, None, None, f"missing_env:{entry.base_url_env}")
    if key:
        return ResolvedProvider(entry, True, base_url.rstrip("/"), key)
    if entry.keyless and entry.locality in _PRIVATE:
        return ResolvedProvider(entry, True, base_url.rstrip("/"), None)
    return ResolvedProvider(entry, False, base_url, None, f"missing_env:{entry.api_key_env}")


def parse_config(raw: Mapping[str, Any]) -> ModelsConfig:
    data = dict(raw)
    data["routes"] = {TaskClass(k): tuple(v or ()) for k, v in (data.get("routes") or {}).items()}
    return ModelsConfig.model_validate(data)


def load_config(path: Path) -> ModelsConfig:
    with path.open("r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: top level must be a mapping")
    return parse_config(raw)


class ConfigSource(Protocol):
    def current(self) -> ModelsConfig: ...

    def resolve(self, provider_id: str) -> ResolvedProvider: ...


class ConfigStore:
    """Reads models.yaml and re-reads it when its mtime or size changes.

    A broken edit keeps the last good config (logged); a broken file at startup raises.
    """

    def __init__(self, path: Path, env: Mapping[str, str] | None = None) -> None:
        self.path = path
        self._env: Mapping[str, str] = env if env is not None else os.environ
        self._stamp: tuple[int, int] | None = None
        self._config = self._read()

    def _stat(self) -> tuple[int, int]:
        st = self.path.stat()
        return (st.st_mtime_ns, st.st_size)

    def _read(self) -> ModelsConfig:
        stamp = self._stat()
        cfg = load_config(self.path)
        self._stamp = stamp
        return cfg

    def current(self) -> ModelsConfig:
        try:
            changed = self._stat() != self._stamp
        except OSError:
            log.warning("models config %s is not readable; keeping the last good version", self.path.name)
            return self._config
        if changed:
            try:
                self._config = self._read()
                log.info("models config reloaded")
            except (OSError, ValueError, yaml.YAMLError) as exc:
                log.error("models config reload failed, keeping the last good version: %s", exc)
                self._stamp = self._stat()
        return self._config

    def resolve(self, provider_id: str) -> ResolvedProvider:
        return resolve_provider(self.current().provider(provider_id), self._env)


class StaticConfig:
    """In-memory config source (tests, tools)."""

    def __init__(self, config: ModelsConfig, env: Mapping[str, str] | None = None) -> None:
        self._config = config
        self._env: Mapping[str, str] = env or {}

    def current(self) -> ModelsConfig:
        return self._config

    def resolve(self, provider_id: str) -> ResolvedProvider:
        return resolve_provider(self._config.provider(provider_id), self._env)
