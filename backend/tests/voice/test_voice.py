from __future__ import annotations

import base64
import json
from collections.abc import Callable
from typing import Any

import httpx
import pytest

from app.core.errors import KillSwitchActive
from app.core.types import DataClass, PrivacyMode
from app.plugins import PluginRegistry
from app.voice.service import classify_text, speakable_redaction
from tests.conftest import PairedDevice

Responder = Callable[[Callable[[httpx.Request], httpx.Response]], None]

TOKEN_OK = {"name": "auth_tokens/abc123"}


async def cloud(registry: PluginRegistry) -> None:
    await registry.service("privacy_state").set_mode(PrivacyMode.CLOUD_INTELLIGENCE)


# ---------------------------------------------------------------- settings and config


async def test_settings_persist_and_config(
    client: httpx.AsyncClient, paired_device: PairedDevice, env: dict[str, str]
) -> None:
    r = await client.get("/v1/voice/config", headers=paired_device.headers)
    assert r.status_code == 200
    body = r.json()
    assert body["settings"]["personality"] == "warm"
    engines = {e["id"]: e for e in body["engines"]}
    assert engines["on_device"]["available"] is True
    # strict private by default: every online engine is unavailable and says why
    assert engines["gemini_tts"]["available"] is False
    assert "Strict private" in engines["gemini_tts"]["reason"]

    put = await client.put(
        "/v1/voice/settings",
        headers=paired_device.headers,
        json={"personality": "crisp", "speaking_rate": 1.25, "engine": "cloud", "voice_gender": "male"},
    )
    assert put.status_code == 200
    again = await client.get("/v1/voice/config", headers=paired_device.headers)
    assert again.json()["settings"]["personality"] == "crisp"
    assert again.json()["settings"]["speaking_rate"] == 1.25

    bad = await client.put("/v1/voice/settings", headers=paired_device.headers, json={"speaking_rate": 9})
    assert bad.status_code == 422


async def test_engine_status_needs_keys_in_cloud_mode(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry, env: dict[str, str]
) -> None:
    await cloud(registry)
    engines = {
        e["id"]: e
        for e in (await client.get("/v1/voice/config", headers=paired_device.headers)).json()["engines"]
    }
    assert engines["gemini_live"] == {
        "id": "gemini_live",
        "available": False,
        "reason": "Needs GEMINI_API_KEY.",
    }
    assert engines["elevenlabs"]["reason"] == "Needs ELEVENLABS_API_KEY."
    env["GEMINI_API_KEY"] = "k-gem"
    env["ELEVENLABS_API_KEY"] = "k-el"
    engines = {
        e["id"]: e
        for e in (await client.get("/v1/voice/config", headers=paired_device.headers)).json()["engines"]
    }
    assert engines["gemini_live"]["available"] is True
    assert engines["gemini_tts"]["available"] is True
    assert engines["elevenlabs"]["available"] is True
    assert engines["google_chirp"]["available"] is False
    caps = {c.id: c for c in registry.capabilities.all(domain="voice")}
    assert caps["voice.tts.google_chirp"].status.value == "requires_credentials"
    assert caps["voice.live"].status.value == "working_integration"


async def test_voice_requires_auth(client: httpx.AsyncClient) -> None:
    assert (await client.get("/v1/voice/config")).status_code == 401
    assert (await client.post("/v1/voice/live-session")).status_code == 401


# ---------------------------------------------------------------- live session


async def test_live_refused_in_strict_private(
    client: httpx.AsyncClient, paired_device: PairedDevice, env: dict[str, str], seen: list[httpx.Request]
) -> None:
    env["GEMINI_API_KEY"] = "k-gem"
    r = await client.post("/v1/voice/live-session", headers=paired_device.headers)
    assert r.status_code == 403
    assert r.json()["code"] == "egress_blocked"
    assert r.json()["detail"]["reason"] == "strict_private_mode"
    assert seen == []


async def test_live_refused_without_key(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    seen: list[httpx.Request],
) -> None:
    await cloud(registry)
    r = await client.post("/v1/voice/live-session", headers=paired_device.headers)
    assert r.status_code == 503
    assert r.json()["code"] == "requires_credentials"
    assert "GEMINI_API_KEY" in r.json()["message"]
    assert seen == []


async def test_live_refused_under_kill_switch(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry, env: dict[str, str]
) -> None:
    await cloud(registry)
    env["GEMINI_API_KEY"] = "k-gem"
    await registry.service("kill_switch").set(True)
    r = await client.post("/v1/voice/live-session", headers=paired_device.headers)
    assert r.status_code == 503
    assert r.json()["code"] == "kill_switch_active"
    # the service itself also refuses, and privacy reports strict private under the kill switch
    with pytest.raises(KillSwitchActive):
        await registry.service("voice").live_session("dev")


async def test_live_session_request_shape(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    seen: list[httpx.Request],
    respond: Responder,
) -> None:
    await cloud(registry)
    env["GEMINI_API_KEY"] = "k-gem"
    respond(lambda req: httpx.Response(200, json=TOKEN_OK))
    r = await client.post("/v1/voice/live-session", headers=paired_device.headers)
    assert r.status_code == 200, r.text
    grant = r.json()
    assert grant["ephemeral_token"] == "auth_tokens/abc123"
    assert grant["provider"] == "gemini"
    assert grant["model"].startswith("models/")
    assert grant["ws_url"].startswith("wss://")
    assert grant["input_sample_rate"] == 16000 and grant["output_sample_rate"] == 24000

    (req,) = seen
    assert req.method == "POST"
    assert str(req.url) == "https://generativelanguage.googleapis.com/v1beta/auth_tokens"
    assert req.headers["x-goog-api-key"] == "k-gem"
    body: dict[str, Any] = json.loads(req.content)
    assert body["uses"] == 1
    assert body["expireTime"].endswith("Z") and body["newSessionExpireTime"].endswith("Z")
    assert body["newSessionExpireTime"] < body["expireTime"]
    constraints = body["liveConnectConstraints"]
    # the model comes from the realtime_voice route of config/models.yaml
    cfg = registry.service("settings").config_dir / "models.yaml"
    assert "models/gemini-3.8-live" == constraints["model"] == grant["model"]
    assert cfg.exists()
    config = constraints["config"]
    assert config["responseModalities"] == ["AUDIO"]
    decls = config["tools"][0]["functionDeclarations"]
    assert [d["name"] for d in decls] == ["ask_zoro"]  # the single tool
    text = config["systemInstruction"]["parts"][0]["text"]
    assert text == grant["system_instruction"]
    assert "ask_zoro" in text and "Speak only what ask_zoro returns" in text
    assert "k-gem" not in r.text  # the API key never reaches the device


@pytest.mark.parametrize(
    ("status", "code", "http"),
    [
        (401, "voice_provider_auth", 503),
        (403, "voice_provider_auth", 503),
        (429, "voice_rate_limited", 429),
        (500, "voice_provider_error", 503),
    ],
)
async def test_live_upstream_errors(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    respond: Responder,
    status: int,
    code: str,
    http: int,
) -> None:
    await cloud(registry)
    env["GEMINI_API_KEY"] = "k-gem"
    respond(lambda req: httpx.Response(status, json={"error": {"message": "x"}}))
    r = await client.post("/v1/voice/live-session", headers=paired_device.headers)
    assert (r.status_code, r.json()["code"]) == (http, code)


async def test_live_response_without_token(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    respond: Responder,
) -> None:
    await cloud(registry)
    env["GEMINI_API_KEY"] = "k-gem"
    respond(lambda req: httpx.Response(200, json={}))
    r = await client.post("/v1/voice/live-session", headers=paired_device.headers)
    assert r.json()["code"] == "voice_provider_error"


# ---------------------------------------------------------------- TTS


def pcm(n: int = 4800) -> bytes:
    return bytes(range(256)) * (n // 256)


async def test_tts_refused_in_strict_private(
    client: httpx.AsyncClient, paired_device: PairedDevice, env: dict[str, str], seen: list[httpx.Request]
) -> None:
    env["ELEVENLABS_API_KEY"] = "k-el"
    env["GEMINI_API_KEY"] = "k-gem"
    r = await client.post("/v1/voice/tts", headers=paired_device.headers, json={"text": "Hello there"})
    assert r.status_code == 403
    assert r.json()["code"] == "egress_blocked"
    assert seen == []  # nothing left the machine


async def test_tts_refused_for_ungranted_classes(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    seen: list[httpx.Request],
) -> None:
    await cloud(registry)
    env["ELEVENLABS_API_KEY"] = "k-el"
    headers = {**paired_device.headers, "X-Zoro-Data-Classes": "financial"}
    r = await client.post("/v1/voice/tts", headers=headers, json={"text": "Your balance is low"})
    assert r.status_code == 403
    assert "class_not_granted" in r.json()["detail"]["reason"]
    # a card number in the text is classified financial even without the header
    r2 = await client.post(
        "/v1/voice/tts", headers=paired_device.headers, json={"text": "Card 4111 1111 1111 1111 was used"}
    )
    assert r2.status_code == 403
    assert seen == []
    assert DataClass.FINANCIAL in classify_text("Card 4111 1111 1111 1111")


async def test_tts_without_any_key(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    await cloud(registry)
    r = await client.post("/v1/voice/tts", headers=paired_device.headers, json={"text": "Hello"})
    assert r.status_code == 503
    assert r.json()["code"] == "requires_credentials"
    assert len(r.json()["detail"]["engines"]) == 3


async def test_tts_elevenlabs_streams_pcm(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    seen: list[httpx.Request],
    respond: Responder,
) -> None:
    await cloud(registry)
    env["ELEVENLABS_API_KEY"] = "k-el"
    audio = pcm()
    respond(lambda req: httpx.Response(200, content=audio, headers={"content-type": "audio/pcm"}))
    r = await client.post(
        "/v1/voice/tts",
        headers=paired_device.headers,
        json={"text": "नमस्ते, कैसे हैं आप?", "language": "hi", "voice_id": "elevenlabs:21m00Tcm4TlvDq8ikWAM"},
    )
    assert r.status_code == 200, r.text
    assert r.content == audio
    assert r.headers["x-zoro-sample-rate"] == "24000"
    assert r.headers["x-zoro-voice-engine"] == "elevenlabs"
    (req,) = seen
    assert req.url.path == "/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM/stream"
    assert req.url.params["output_format"] == "pcm_24000"
    assert req.headers["xi-api-key"] == "k-el"
    body = json.loads(req.content)
    assert body["text"] == "नमस्ते, कैसे हैं आप?"
    assert body["model_id"] == "eleven_flash_v2_5"


async def test_tts_gemini_parses_sse_audio(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    seen: list[httpx.Request],
    respond: Responder,
) -> None:
    await cloud(registry)
    env["GEMINI_API_KEY"] = "k-gem"
    a, b = pcm(960), pcm(480)
    sse = "".join(
        f"data: {json.dumps({'event_type': 'step.delta', 'delta': {'type': 'audio', 'data': base64.b64encode(x).decode()}})}\n\n"
        for x in (a, b)
    )
    respond(
        lambda req: httpx.Response(200, content=sse.encode(), headers={"content-type": "text/event-stream"})
    )
    r = await client.post("/v1/voice/tts", headers=paired_device.headers, json={"text": "Good morning"})
    assert r.status_code == 200, r.text
    assert r.content == a + b
    assert r.headers["x-zoro-voice-engine"] == "gemini_tts"
    (req,) = seen
    assert req.url.path == "/v1beta/interactions"
    assert req.headers["x-goog-api-key"] == "k-gem"
    body = json.loads(req.content)
    assert body["stream"] is True
    assert body["model"] == "gemini-3.8-flash-lite-tts"  # from the tts route in models.yaml
    assert body["generation_config"]["speech_config"][0]["voice"] == "Kore"


async def test_tts_chirp_strips_wav_header_and_uses_hindi_locale(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    seen: list[httpx.Request],
    respond: Responder,
) -> None:
    await cloud(registry)
    env["GOOGLE_TTS_API_KEY"] = "k-g"
    audio = pcm(2400)
    wav = b"RIFF" + b"\x00" * 40 + audio
    respond(lambda req: httpx.Response(200, json={"audioContent": base64.b64encode(wav).decode()}))
    r = await client.post(
        "/v1/voice/tts",
        headers=paired_device.headers,
        json={"text": "Aaj mausam accha hai", "language": "hinglish"},
    )
    assert r.status_code == 200, r.text
    assert r.content == audio
    (req,) = seen
    body = json.loads(req.content)
    assert body["voice"]["languageCode"] == "hi-IN"
    assert body["voice"]["name"] == "hi-IN-Chirp3-HD-Kore"
    assert body["audioConfig"]["audioEncoding"] == "LINEAR16"


async def test_tts_redacts_identifiers_before_sending(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    seen: list[httpx.Request],
    respond: Responder,
) -> None:
    await cloud(registry)
    env["ELEVENLABS_API_KEY"] = "k-el"
    respond(lambda req: httpx.Response(200, content=pcm(960)))
    r = await client.post(
        "/v1/voice/tts", headers=paired_device.headers, json={"text": "Call 98765 43210 about the delivery"}
    )
    assert r.status_code == 200
    sent = json.loads(seen[0].content)["text"]
    assert "98765" not in sent and "a phone number" in sent
    assert speakable_redaction("mail me at a@b.com") == "mail me at an email address"


async def test_tts_upstream_errors_and_validation(
    client: httpx.AsyncClient,
    paired_device: PairedDevice,
    registry: PluginRegistry,
    env: dict[str, str],
    respond: Responder,
) -> None:
    await cloud(registry)
    env["ELEVENLABS_API_KEY"] = "k-el"
    respond(lambda req: httpx.Response(429))
    r = await client.post("/v1/voice/tts", headers=paired_device.headers, json={"text": "Hello"})
    assert (r.status_code, r.json()["code"]) == (429, "voice_rate_limited")
    respond(lambda req: httpx.Response(401))
    r = await client.post("/v1/voice/tts", headers=paired_device.headers, json={"text": "Hello"})
    assert r.json()["code"] == "voice_provider_auth"
    r = await client.post("/v1/voice/tts", headers=paired_device.headers, json={"text": "   "})
    assert r.json()["code"] == "text_empty"
    r = await client.post("/v1/voice/tts", headers=paired_device.headers, json={"text": "x" * 6000})
    assert r.json()["code"] == "text_too_long"
    r = await client.post(
        "/v1/voice/tts", headers=paired_device.headers, json={"text": "Hi", "voice_id": "nope:zzz"}
    )
    assert r.json()["code"] == "voice_not_found"
    r = await client.post(
        "/v1/voice/tts", headers=paired_device.headers, json={"text": "Hi", "voice_id": "on_device"}
    )
    assert r.json()["code"] == "no_voice_engine"
