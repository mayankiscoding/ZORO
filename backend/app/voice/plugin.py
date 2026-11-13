"""Registers the voice package: settings, live-session grants, TTS, permission and capabilities."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import httpx

from app.core.types import CapabilityStatus, IntegrationLevel
from app.providers.config import ConfigSource, ConfigStore
from app.providers.plugin import config_path
from app.schemas.security import Capability
from app.voice.api import router
from app.voice.config import VoicesStore
from app.voice.service import VoiceService
from app.voice.store import VoiceSettingsStore

PERM_VOICE = "voice.cloud"


def voice_capabilities(service: VoiceService, voices: VoicesStore, models: ConfigSource) -> list[Capability]:
    """Status reflects configuration only (key present); reachability is never checked here."""
    cfg = voices.current()
    caps = [
        Capability(
            id="voice.on_device",
            title="On-device speech",
            domain="voice",
            status=CapabilityStatus.WORKING_NATIVE,
            integration_level=IntegrationLevel.FULLY_INTEGRATED,
            note="Speech recognition and system voice run on the device.",
        )
    ]
    live_ready = models.resolve(cfg.live.provider).api_key is not None
    caps.append(
        Capability(
            id="voice.live",
            title="Realtime voice (Gemini Live)",
            domain="voice",
            status=CapabilityStatus.WORKING_INTEGRATION
            if live_ready
            else CapabilityStatus.REQUIRES_CREDENTIALS,
            integration_level=IntegrationLevel.OFFICIAL_API,
            requires=[] if live_ready else ["GEMINI_API_KEY"],
            note="Cloud mode only; the device receives a short-lived single-use token, never the key. "
            "WebSocket details are unverified against the live service.",
        )
    )
    for engine_id, engine in cfg.tts.engines.items():
        key, _url, _reason = service.engine_key(engine)
        ready = key is not None
        needs = engine.key_env or "GEMINI_API_KEY"
        caps.append(
            Capability(
                id=f"voice.tts.{engine_id}",
                title=f"Online speech: {engine_id}",
                domain="voice",
                status=CapabilityStatus.WORKING_INTEGRATION
                if ready
                else CapabilityStatus.REQUIRES_CREDENTIALS,
                integration_level=IntegrationLevel.OFFICIAL_API,
                requires=[] if ready else [needs],
                note="Cloud mode only; reachability is not checked.",
            )
        )
    return caps


def install(
    reg: Any,
    *,
    models: ConfigSource | None = None,
    voices_path: Path | None = None,
    http: Any = None,
    env: Any = None,
) -> VoiceService:
    settings = reg.service("settings")
    models = models or ConfigStore(config_path(settings))
    voices = VoicesStore(voices_path or Path(settings.config_dir) / "voices.yaml")
    factory = http or (lambda: httpx.AsyncClient(timeout=httpx.Timeout(30.0, connect=5.0)))
    service = VoiceService(
        store=VoiceSettingsStore(reg.service("session_factory"), reg.service("clock")),
        voices=voices,
        models=models,
        http=factory,
        clock=reg.service("clock"),
        privacy=reg.service("privacy_state"),
        kill_switch=reg.service("kill_switch"),
        audit=reg.service("audit"),
        env=env,
    )
    reg.provide("voice", service)
    reg.add_permission(PERM_VOICE, "Let ZORO use online voice services in cloud mode", True)
    reg.add_router(router)
    reg.add_capability(lambda: voice_capabilities(service, voices, models))
    return service


def register(reg: Any) -> None:
    install(reg)
