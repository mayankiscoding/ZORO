"""One loader for the runtime YAML files that are not owned by a single package.

- ``config/integrations.yaml``  official provider endpoints and OAuth scopes (CLAUDE.md rule 7)
- ``config/orchestrator.yaml``  per-turn limits and the routing confidence threshold

Files are validated with Pydantic and cached by modification time, so an edit is picked up on the
next call without a restart. A missing integration is an error (the package asked for something
that is not configured); a missing or malformed orchestrator file falls back to the documented
defaults and logs a warning, so the assistant keeps answering.
"""

from __future__ import annotations

import logging
import threading
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

log = logging.getLogger(__name__)

INTEGRATIONS_FILE = "integrations.yaml"
ORCHESTRATOR_FILE = "orchestrator.yaml"


class _Strict(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class IntegrationEntry(_Strict):
    title: str
    docs_url: str | None = None
    credentials_env: tuple[str, ...] = ()
    urls: dict[str, str]
    scopes: tuple[str, ...] = ()

    @field_validator("urls")
    @classmethod
    def _https_only(cls, value: dict[str, str]) -> dict[str, str]:
        for name, url in value.items():
            if not url.startswith("https://"):
                raise ValueError(f"integration url {name!r} must use https")
        return value


class IntegrationsFile(_Strict):
    version: int = 1
    integrations: dict[str, IntegrationEntry] = Field(default_factory=dict)


class TurnLimitsConfig(_Strict):
    recursion_limit: int = Field(40, ge=5, le=200)
    max_tool_calls: int = Field(24, ge=1, le=200)
    max_tokens: int = Field(60_000, ge=1_000, le=1_000_000)
    max_seconds: float = Field(120.0, ge=5, le=900)


class RoutingConfig(_Strict):
    confidence_threshold: float = Field(0.6, gt=0, le=1)
    low_confidence_floor: float = Field(0.5, ge=0, le=1)


class OrchestratorConfig(_Strict):
    version: int = 1
    turn_limits: TurnLimitsConfig = TurnLimitsConfig()
    routing: RoutingConfig = RoutingConfig()

    def turn_limits_kwargs(self) -> dict[str, Any]:
        """Keyword arguments for `app.orchestrator.state.TurnLimits`."""
        return self.turn_limits.model_dump()


class IntegrationNotConfigured(LookupError):
    pass


_cache: dict[tuple[Path, type[BaseModel]], tuple[float, BaseModel]] = {}
_lock = threading.Lock()


def default_config_dir() -> Path:
    from app.core.settings import get_settings

    return Path(get_settings().config_dir)


def _load[M: BaseModel](path: Path, model: type[M]) -> M:
    """Parse and validate `path`, cached by mtime. Raises OSError / ValueError on problems."""
    mtime = path.stat().st_mtime
    key = (path.resolve(), model)
    with _lock:
        hit = _cache.get(key)
        if hit is not None and hit[0] == mtime:
            return hit[1]  # type: ignore[return-value]
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(raw, dict):
        raise ValueError(f"{path.name}: top level must be a mapping")
    parsed = model.model_validate(raw)
    with _lock:
        _cache[key] = (mtime, parsed)
    return parsed


def load_integrations(config_dir: Path | None = None) -> IntegrationsFile:
    return _load((config_dir or default_config_dir()) / INTEGRATIONS_FILE, IntegrationsFile)


def integration(name: str, config_dir: Path | None = None) -> IntegrationEntry:
    entry = load_integrations(config_dir).integrations.get(name)
    if entry is None:
        raise IntegrationNotConfigured(f"integration {name!r} is not in config/{INTEGRATIONS_FILE}")
    return entry


def integration_urls(name: str, config_dir: Path | None = None) -> dict[str, str]:
    """Endpoint URLs of one integration keyed by role, e.g. ``SpotifyEndpoints(**integration_urls("spotify"))``."""
    return dict(integration(name, config_dir).urls)


def integration_scopes(name: str, config_dir: Path | None = None) -> tuple[str, ...]:
    return integration(name, config_dir).scopes


def orchestrator_config(config_dir: Path | None = None) -> OrchestratorConfig:
    path = (config_dir or default_config_dir()) / ORCHESTRATOR_FILE
    try:
        return _load(path, OrchestratorConfig)
    except FileNotFoundError:
        return OrchestratorConfig()
    except (OSError, ValueError, ValidationError, yaml.YAMLError) as exc:
        log.warning(
            "orchestrator config unreadable; using defaults",
            extra={"file": path.name, "error_type": type(exc).__name__},
        )
        return OrchestratorConfig()


def clear_cache() -> None:
    with _lock:
        _cache.clear()
