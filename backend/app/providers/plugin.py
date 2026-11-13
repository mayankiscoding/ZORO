"""Registers the model gateway with the kernel's plugin registry.

Kernel modules (app.api.deps, the registry) are imported lazily inside `register` so this package
imports cleanly on its own.
"""

from __future__ import annotations

import importlib
import os
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from app.core.types import CapabilityStatus, IntegrationLevel, Locality
from app.providers.config import ConfigSource, ConfigStore
from app.providers.gateway import ModelGateway
from app.providers.usage import DbUsageSink
from app.schemas.security import Capability

_REPO_CONFIG = Path(__file__).resolve().parents[3] / "config"


def config_path(settings: Any, env: Mapping[str, str] | None = None) -> Path:
    env = os.environ if env is None else env
    configured = getattr(settings, "config_dir", None) or env.get("ZORO_CONFIG_DIR")
    return Path(configured) / "models.yaml" if configured else _REPO_CONFIG / "models.yaml"


def provider_capabilities(config: ConfigSource) -> list[Capability]:
    """One capability per provider. Status reflects configuration only, never live connectivity."""
    caps: list[Capability] = []
    for p in config.current().providers:
        rp = config.resolve(p.id)
        requires = [e for e in (p.api_key_env, p.base_url_env) if e]
        if not rp.enabled:
            status = CapabilityStatus.REQUIRES_CREDENTIALS if p.enabled else CapabilityStatus.UNAVAILABLE
            note = f"Disabled: {rp.disabled_reason}."
        elif p.locality is Locality.EXTERNAL:
            status = CapabilityStatus.WORKING_INTEGRATION
            note = "Credentials present; reachability is not checked."
        else:
            status = CapabilityStatus.WORKING_LOCAL
            note = "Configured local server; reachability is not checked."
        caps.append(
            Capability(
                id=f"models.{p.id}",
                title=f"Model provider: {p.id}",
                domain="models",
                status=status,
                integration_level=IntegrationLevel.OFFICIAL_API,
                requires=requires,
                note=note,
            )
        )
    return caps


def _optional_service(reg: Any, name: str) -> Any:
    try:
        return reg.service(name)
    except (KeyError, LookupError):
        return None


def register(reg: Any) -> None:
    from app.providers.api import build_router

    # Kernel module, imported lazily on purpose (and by name so this package type-checks without it).
    require_device = importlib.import_module("app.api.deps").require_device

    settings = reg.service("settings")
    session_factory = reg.service("session_factory")
    privacy_state = _optional_service(reg, "privacy_state")  # None: most restrictive overrides
    kill_switch = _optional_service(reg, "kill_switch")
    config = ConfigStore(config_path(settings))
    gateway = ModelGateway(
        config,
        privacy_state=privacy_state,
        kill_switch=kill_switch,
        usage=DbUsageSink(session_factory),
    )
    reg.provide("gateway", gateway)
    reg.add_router(build_router(gateway, session_factory, require_device))
    for cap in provider_capabilities(config):
        reg.add_capability(cap)
    reg.add_shutdown(gateway.aclose)
