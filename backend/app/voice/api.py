"""`/v1/voice`: config, settings, live-session grant, streaming TTS."""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header
from starlette.responses import StreamingResponse

from app.api.deps import CurrentDevice, Registry, require_device
from app.core.types import DataClass
from app.schemas.data import LiveSessionGrant, TTSRequest, VoiceConfig, VoiceSettings
from app.voice.service import VoiceService

router = APIRouter(prefix="/voice", tags=["voice"], dependencies=[Depends(require_device)])


def _service(reg: Registry) -> VoiceService:
    service: VoiceService = reg.service("voice")
    return service


def parse_classes(header: str | None) -> list[DataClass]:
    """`X-Zoro-Data-Classes: personal,financial`. Unknown names are ignored (the text is classified too)."""
    out: list[DataClass] = []
    for part in (header or "").split(","):
        try:
            out.append(DataClass(part.strip().lower()))
        except ValueError:
            continue
    return out


@router.get("/config", response_model=VoiceConfig)
async def get_config(reg: Registry) -> VoiceConfig:
    return await _service(reg).config()


@router.put("/settings", response_model=VoiceSettings)
async def put_settings(body: VoiceSettings, reg: Registry) -> VoiceSettings:
    return await _service(reg).update_settings(body)


@router.post("/live-session", response_model=LiveSessionGrant)
async def live_session(reg: Registry, device: CurrentDevice) -> LiveSessionGrant:
    return await _service(reg).live_session(device.device_id)


@router.post("/tts", response_class=StreamingResponse)
async def tts(
    body: TTSRequest,
    reg: Registry,
    device: CurrentDevice,
    x_zoro_data_classes: Annotated[str | None, Header()] = None,
) -> Any:
    """Streams raw 16-bit little-endian mono PCM. `X-Zoro-Sample-Rate` says the rate.
    Send `X-Zoro-Data-Classes` (the classes of the text, e.g. from the turn) so the egress check
    is exact; without it the text counts as personal."""
    stream = await _service(reg).synthesize(
        body, device_id=device.device_id, declared=parse_classes(x_zoro_data_classes)
    )
    return StreamingResponse(
        stream.chunks,
        media_type="audio/L16",
        headers={
            "X-Zoro-Sample-Rate": str(stream.sample_rate),
            "X-Zoro-Voice-Engine": stream.engine,
            "X-Zoro-Voice": stream.voice,
            "Cache-Control": "no-store",
        },
    )
