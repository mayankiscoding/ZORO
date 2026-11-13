"""`/v1/auth`: pairing, challenge, token. These answer even while the kill switch is on."""

from __future__ import annotations

from fastapi import APIRouter

from app.api.dependencies import Registry
from app.schemas.auth import (
    ChallengeRequest,
    ChallengeResponse,
    PairRequest,
    PairResponse,
    TokenRequest,
    TokenResponse,
)

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/pair", response_model=PairResponse)
async def pair(body: PairRequest, reg: Registry) -> PairResponse:
    device = await reg.service("devices").pair(body)
    await reg.service("audit").append(
        actor=device.id, action="device.paired", decision="info", detail=f"platform={device.platform.value}"
    )
    return PairResponse(
        device_id=device.id,
        server_name=reg.service("settings").server_name,
        server_time=reg.service("clock").now(),
    )


@router.post("/challenge", response_model=ChallengeResponse)
async def challenge(body: ChallengeRequest, reg: Registry) -> ChallengeResponse:
    result: ChallengeResponse = await reg.service("sessions").create_challenge(body.device_id)
    return result


@router.post("/token", response_model=TokenResponse)
async def token(body: TokenRequest, reg: Registry) -> TokenResponse:
    result: TokenResponse = await reg.service("sessions").issue_token(body)
    return result
