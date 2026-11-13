"""TTS adapters: each turns text into a stream of 16-bit little-endian mono PCM at `sample_rate`.

Request shapes: ElevenLabs is verified against its API reference; Gemini TTS (Interactions API) and
Chirp 3 HD (REST + API key) are marked UNVERIFIED in config/voices.yaml. Error statuses are mapped
before any audio is yielded, so the router can answer with an `ErrorBody` instead of a broken stream.
"""

from __future__ import annotations

import base64
import binascii
import json
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass
from typing import Any, Protocol

import httpx

from app.voice.errors import VoiceProviderAuth, VoiceProviderError, VoiceRateLimited

HttpFactory = Callable[[], httpx.AsyncClient]
_TIMEOUT = httpx.Timeout(30.0, connect=5.0, read=30.0)
_CHUNK = 9600  # 200 ms at 24 kHz, 16-bit mono


class TTSAdapter(Protocol):
    engine_id: str

    def stream(self, job: TTSJob) -> AsyncIterator[bytes]: ...


@dataclass(frozen=True)
class TTSJob:
    text: str
    language: str  # en | hi | hinglish
    voice_id: str  # engine-specific voice
    rate: float
    api_key: str
    base_url: str
    sample_rate: int
    model: str | None = None
    locale: str | None = None  # Chirp
    output_format: str | None = None  # ElevenLabs


def raise_for_status(status: int) -> None:
    if status in (401, 403):
        raise VoiceProviderAuth()
    if status == 429:
        raise VoiceRateLimited()
    if status >= 400:
        raise VoiceProviderError(detail={"status": status})


def strip_wav_header(data: bytes) -> bytes:
    """LINEAR16 from Google carries a 44-byte RIFF header; the device wants raw PCM."""
    return data[44:] if data[:4] == b"RIFF" else data


def _decode(b64: str) -> bytes:
    try:
        return base64.b64decode(b64, validate=False)
    except (binascii.Error, ValueError) as exc:
        raise VoiceProviderError("The voice service returned audio that could not be decoded.") from exc


class GeminiTTS:
    engine_id = "gemini_tts"

    def __init__(self, http: HttpFactory) -> None:
        self._http = http

    async def stream(self, job: TTSJob) -> AsyncIterator[bytes]:
        body: dict[str, Any] = {
            "model": job.model,
            "input": [{"type": "user_input", "content": [{"type": "text", "text": job.text}]}],
            "response_format": {"type": "audio", "mime_type": "audio/l16", "sample_rate": job.sample_rate},
            "generation_config": {"speech_config": [{"voice": job.voice_id}]},
            "stream": True,
        }
        try:
            async with (
                self._http() as client,
                client.stream(
                    "POST",
                    f"{job.base_url.rstrip('/')}/interactions",
                    json=body,
                    headers={"x-goog-api-key": job.api_key},
                    timeout=_TIMEOUT,
                ) as response,
            ):
                raise_for_status(response.status_code)
                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if not payload or payload == "[DONE]":
                        continue
                    try:
                        event = json.loads(payload)
                    except ValueError:
                        continue
                    delta = event.get("delta") if isinstance(event, dict) else None
                    if isinstance(delta, dict) and delta.get("type") == "audio" and delta.get("data"):
                        yield _decode(str(delta["data"]))
        except httpx.HTTPError as exc:
            raise VoiceProviderError("The voice service could not be reached.") from exc


class ElevenLabsTTS:
    engine_id = "elevenlabs"

    def __init__(self, http: HttpFactory) -> None:
        self._http = http

    async def stream(self, job: TTSJob) -> AsyncIterator[bytes]:
        body = {
            "text": job.text,
            "model_id": job.model,
            "voice_settings": {"speed": min(1.2, max(0.7, job.rate))},
        }
        url = f"{job.base_url.rstrip('/')}/v1/text-to-speech/{job.voice_id}/stream"
        try:
            async with (
                self._http() as client,
                client.stream(
                    "POST",
                    url,
                    params={"output_format": job.output_format or "pcm_24000"},
                    json=body,
                    headers={"xi-api-key": job.api_key},
                    timeout=_TIMEOUT,
                ) as response,
            ):
                raise_for_status(response.status_code)
                async for chunk in response.aiter_bytes(_CHUNK):
                    if chunk:
                        yield chunk
        except httpx.HTTPError as exc:
            raise VoiceProviderError("The voice service could not be reached.") from exc


class ChirpTTS:
    """Chirp 3 HD through `text:synthesize` (one response, re-chunked so the device can start early)."""

    engine_id = "google_chirp"

    def __init__(self, http: HttpFactory) -> None:
        self._http = http

    async def stream(self, job: TTSJob) -> AsyncIterator[bytes]:
        locale = job.locale or "en-IN"
        body = {
            "input": {"text": job.text},
            "voice": {"languageCode": locale, "name": f"{locale}-Chirp3-HD-{job.voice_id}"},
            "audioConfig": {
                "audioEncoding": "LINEAR16",
                "sampleRateHertz": job.sample_rate,
                "speakingRate": min(2.0, max(0.25, job.rate)),
            },
        }
        try:
            async with self._http() as client:
                response = await client.post(
                    f"{job.base_url.rstrip('/')}/text:synthesize",
                    json=body,
                    headers={"x-goog-api-key": job.api_key},
                    timeout=_TIMEOUT,
                )
        except httpx.HTTPError as exc:
            raise VoiceProviderError("The voice service could not be reached.") from exc
        raise_for_status(response.status_code)
        try:
            content = response.json().get("audioContent")
        except ValueError:
            content = None
        if not isinstance(content, str) or not content:
            raise VoiceProviderError("The voice service returned no audio.")
        pcm = strip_wav_header(_decode(content))
        for start in range(0, len(pcm), _CHUNK):
            yield pcm[start : start + _CHUNK]


async def align_pcm(chunks: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
    """Never split a 16-bit sample across two chunks."""
    carry = b""
    async for chunk in chunks:
        data = carry + chunk
        cut = len(data) - (len(data) % 2)
        carry = data[cut:]
        if cut:
            yield data[:cut]
