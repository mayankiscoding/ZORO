"""VoiceService: settings, engine status, live-session grants and TTS with the egress check."""

from __future__ import annotations

import logging
import os
import re
from collections.abc import AsyncIterator, Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Any

import httpx

from app.core.clock import Clock
from app.core.errors import BadRequest, ZoroError
from app.core.types import DataClass, Locality, PrivacyMode, TaskClass
from app.providers.config import ConfigSource
from app.schemas.data import (
    LiveSessionGrant,
    TTSRequest,
    VoiceConfig,
    VoiceEngineStatus,
    VoiceOption,
    VoiceSettings,
)
from app.security.egress import DEFAULT_EXTERNAL_CLASSES, decide_egress
from app.security.redaction import redact_text
from app.voice.config import EngineConfig, EngineId, VoiceEntry, VoicesStore
from app.voice.errors import EgressBlocked, NoVoiceEngine, RequiresCredentials, VoiceNotFound
from app.voice.live import LiveSessionMinter
from app.voice.store import VoiceSettingsStore
from app.voice.tts import ChirpTTS, ElevenLabsTTS, GeminiTTS, TTSAdapter, TTSJob, align_pcm

log = logging.getLogger(__name__)

MAX_TTS_CHARS = 5000
_FINANCIAL_KINDS = {"card", "bank_account", "upi", "ifsc"}
_SENSITIVE_KINDS = {"aadhaar", "pan"}
_SPOKEN = {
    "email": "an email address",
    "upi": "a UPI ID",
    "bank_account": "an account number",
    "card": "a card number",
    "aadhaar": "an Aadhaar number",
    "ifsc": "a bank code",
    "pan": "a PAN number",
    "phone": "a phone number",
}
_PLACEHOLDER = re.compile(r"\[redacted:([a-z_]+)\]")


def classify_text(text: str, declared: Iterable[DataClass] = ()) -> frozenset[DataClass]:
    """Data classes of a text to be spoken: what the caller declared, plus what the text shows.
    Unknown is PERSONAL, never PUBLIC."""
    classes = set(declared)
    for kind in redact_text(text).counts:
        if kind in _FINANCIAL_KINDS:
            classes.add(DataClass.FINANCIAL)
        elif kind in _SENSITIVE_KINDS:
            classes.add(DataClass.SENSITIVE)
        else:
            classes.add(DataClass.PERSONAL)
    return frozenset(classes or {DataClass.PERSONAL})


def speakable_redaction(text: str) -> str:
    masked = redact_text(text).text
    return _PLACEHOLDER.sub(lambda m: _SPOKEN.get(m.group(1), "something private"), masked)


@dataclass
class TTSStream:
    engine: str
    voice: str
    sample_rate: int
    chunks: AsyncIterator[bytes]


class VoiceService:
    def __init__(
        self,
        *,
        store: VoiceSettingsStore,
        voices: VoicesStore,
        models: ConfigSource,
        http: Callable[[], httpx.AsyncClient],
        clock: Clock,
        privacy: Any,
        kill_switch: Any,
        audit: Any | None = None,
        env: Mapping[str, str] | None = None,
    ) -> None:
        self._store = store
        self._voices = voices
        self._models = models
        self._http = http
        self._privacy = privacy
        self._kill = kill_switch
        self._audit = audit
        self._env: Mapping[str, str] = env if env is not None else os.environ
        self._minter = LiveSessionMinter(
            models=models, live=lambda: voices.current().live, http=http, clock=clock
        )
        self._adapters: dict[str, TTSAdapter] = {
            "gemini_tts": GeminiTTS(http),
            "google_chirp": ChirpTTS(http),
            "elevenlabs": ElevenLabsTTS(http),
        }

    # ------------------------------------------------------------ settings

    async def get_settings(self) -> VoiceSettings:
        return await self._store.get()

    async def update_settings(self, settings: VoiceSettings) -> VoiceSettings:
        return await self._store.put(settings)

    # ------------------------------------------------------------ engine resolution

    def engine_key(self, engine: EngineConfig) -> tuple[str | None, str | None, str | None]:
        """(api_key, base_url, reason when unavailable)."""
        if engine.provider:  # Gemini: key and URL come from models.yaml
            resolved = self._models.resolve(engine.provider)
            if not resolved.enabled or not resolved.api_key:
                return None, None, "Needs GEMINI_API_KEY."
            return resolved.api_key, resolved.base_url, None
        key = (self._env.get(engine.key_env, "") if engine.key_env else "").strip()
        if not key:
            return None, None, f"Needs {engine.key_env}."
        return key, engine.base_url, None

    def _gemini_tts_model(self, engine: EngineConfig) -> str | None:
        cfg = self._models.current()
        for model_id in cfg.route(TaskClass.TTS):
            model = cfg.model(model_id)
            if model.provider == engine.provider and "tts" in model.capabilities:
                return model.model_name
        return None

    async def _mode(self) -> PrivacyMode:
        mode: PrivacyMode = await self._privacy.get_mode()
        return mode

    async def _granted(self) -> frozenset[DataClass]:
        _strict_public, extra = await self._privacy.egress_overrides()
        return frozenset(extra) | DEFAULT_EXTERNAL_CLASSES

    async def config(self) -> VoiceConfig:
        cfg = self._voices.current()
        mode = await self._mode()
        killed = await self._kill.is_on()
        engines = [
            VoiceEngineStatus(
                id="on_device", available=True, reason="Runs on your device; nothing leaves it."
            )
        ]

        def external_reason(missing: str | None) -> str | None:
            if killed:
                return "The kill switch is on."
            if mode is PrivacyMode.STRICT_PRIVATE:
                return "Strict private mode keeps speech on your device."
            return missing

        live_reason = external_reason(self._live_missing())
        engines.append(
            VoiceEngineStatus(id="gemini_live", available=live_reason is None, reason=live_reason or "")
        )
        voices = [
            VoiceOption(
                id="on_device",
                name="On-device voice",
                engine="on_device",
                gender="neutral",
                languages=["en", "hi", "hinglish"],
            )
        ]
        for engine_id in cfg.tts.order:
            engine = cfg.tts.engines.get(engine_id)
            if engine is None:
                continue
            _key, _url, missing = self.engine_key(engine)
            if engine.provider and missing is None and self._gemini_tts_model(engine) is None:
                missing = "No TTS model is configured in config/models.yaml."
            reason = external_reason(missing)
            engines.append(VoiceEngineStatus(id=engine_id, available=reason is None, reason=reason or ""))
            voices += [
                VoiceOption(
                    id=f"{engine_id}:{v.id}",
                    name=v.name,
                    engine=engine_id,
                    gender=v.gender,
                    languages=list(v.languages),
                )
                for v in engine.voices
            ]
        return VoiceConfig(settings=await self._store.get(), engines=engines, voices=voices)

    def _live_missing(self) -> str | None:
        live = self._voices.current().live
        resolved = self._models.resolve(live.provider)
        return None if resolved.enabled and resolved.api_key else "Needs GEMINI_API_KEY."

    # ------------------------------------------------------------ live session

    async def live_session(self, device_id: str) -> LiveSessionGrant:
        killed = bool(await self._kill.is_on())
        mode = await self._mode()
        granted = await self._granted()
        try:
            grant = await self._minter.mint(
                mode=mode, killed=killed, settings=await self._store.get(), granted=granted
            )
        except ZoroError as exc:
            await self._note(device_id, "voice.live_session", "denied", exc.error_code)
            raise
        await self._note(device_id, "voice.live_session", "allowed", "token minted")
        return grant

    # ------------------------------------------------------------ TTS

    def _pick_voice(
        self, engine: EngineConfig, wanted: str | None, settings: VoiceSettings, language: str
    ) -> VoiceEntry | None:
        usable = [v for v in engine.voices if language in v.languages] or list(engine.voices)
        if wanted:
            return next((v for v in usable if v.id == wanted), None)
        return next((v for v in usable if v.gender == settings.voice_gender), usable[0] if usable else None)

    async def synthesize(
        self, request: TTSRequest, *, device_id: str, declared: Iterable[DataClass] = ()
    ) -> TTSStream:
        text = request.text.strip()
        if not text:
            raise BadRequest("There is no text to speak.", code="text_empty")
        if len(text) > MAX_TTS_CHARS:
            raise BadRequest(f"Text is longer than {MAX_TTS_CHARS} characters.", code="text_too_long")
        classes = classify_text(text, declared)
        mode = await self._mode()
        if await self._kill.is_on():
            await self._note(device_id, "voice.tts", "blocked", "kill_switch", classes)
            raise EgressBlocked("The kill switch is on.", detail={"reason": "kill_switch"})

        settings = await self._store.get()
        cfg = self._voices.current().tts
        wanted = request.voice_id or settings.voice_id
        only_engine: str | None = None
        voice_id: str | None = None
        if wanted and wanted != "on_device":
            if ":" in wanted:
                only_engine, voice_id = wanted.split(":", 1)
            else:
                voice_id = wanted
        elif wanted == "on_device":
            raise NoVoiceEngine("The on-device voice is selected; speak it on the device.")
        if only_engine and only_engine not in cfg.engines:
            raise VoiceNotFound()

        granted = await self._granted()
        missing: list[str] = []
        blocked_reason: str | None = None
        for engine_id in cfg.order:
            if only_engine and engine_id != only_engine:
                continue
            engine = cfg.engines.get(engine_id)
            if engine is None:
                continue
            decision = decide_egress(
                mode=mode, data_classes=classes, locality=Locality.EXTERNAL,
                provider_allowed=engine.allowed_data_classes & granted,
            )  # fmt: skip
            if not decision.allowed:
                blocked_reason = decision.reason
                break
            key, base_url, reason = self.engine_key(engine)
            voice = self._pick_voice(engine, voice_id, settings, request.language)
            model = self._gemini_tts_model(engine) if engine.provider else engine.model_id
            if key is None or base_url is None or voice is None or (engine.provider and model is None):
                missing.append(f"{engine_id}: {reason or 'no matching voice'}")
                continue
            spoken = speakable_redaction(text) if decision.redact else text
            job = TTSJob(
                text=spoken, language=request.language, voice_id=voice.id, rate=settings.speaking_rate,
                api_key=key, base_url=base_url, sample_rate=engine.sample_rate, model=model,
                locale=engine.locales.get(request.language), output_format=engine.output_format,
            )  # fmt: skip
            await self._note(device_id, "voice.tts", "allowed", f"{engine_id} {decision.reason}", classes)
            return await self._start(engine_id, voice.id, job)

        if blocked_reason is not None:
            await self._note(device_id, "voice.tts", "blocked", blocked_reason, classes)
            raise EgressBlocked(
                "This text may not go to an online voice service under your privacy settings. "
                "ZORO will speak it with the on-device voice.",
                detail={"reason": blocked_reason},
            )
        if missing:
            raise RequiresCredentials(detail={"engines": missing})
        raise NoVoiceEngine()

    async def _start(self, engine_id: EngineId, voice: str, job: TTSJob) -> TTSStream:
        adapter = self._adapters[engine_id]
        chunks = align_pcm(adapter.stream(job))
        try:
            first = await anext(chunks)
        except StopAsyncIteration:
            raise NoVoiceEngine("The voice service returned no audio.") from None

        async def rest() -> AsyncIterator[bytes]:
            yield first
            try:
                async for chunk in chunks:
                    yield chunk
            except ZoroError:
                log.warning("tts stream ended early", extra={"engine": engine_id})

        return TTSStream(engine=engine_id, voice=voice, sample_rate=job.sample_rate, chunks=rest())

    async def _note(
        self, actor: str, action: str, decision: str, detail: str, classes: Iterable[DataClass] = ()
    ) -> None:
        if self._audit is None:
            return
        await self._audit.append(
            actor=actor, action=action, decision=decision, data_classes=classes, detail=detail
        )
