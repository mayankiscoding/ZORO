"""`/v1/music`: connect (PKCE), callback, disconnect, status and the shared session context."""

from __future__ import annotations

from html import escape

from fastapi import APIRouter, Depends, Query
from starlette.responses import HTMLResponse

from app.api.deps import CurrentDevice, Registry, require_device
from app.core.errors import BadRequest, Unavailable
from app.music.schemas import (
    ConnectOut,
    MusicSession,
    MusicSessionUpdate,
    MusicStatus,
    SpotifyStatus,
)
from app.music.service import MusicService
from app.music.spotify import SpotifyClient, SpotifyError

router = APIRouter(prefix="/music", tags=["music"])
_auth = [Depends(require_device)]


class SpotifyNotConfigured(Unavailable):
    code = "requires_credentials"
    retryable = False
    default_message = (
        "Spotify needs SPOTIFY_CLIENT_ID on the server (create an app in the Spotify dashboard)."
    )


def _service(reg: Registry) -> MusicService:
    service: MusicService = reg.service("music")
    return service


def _redirect(reg: Registry) -> str:
    return f"{str(reg.service('settings').public_base_url).rstrip('/')}/v1/music/callback"


@router.post("/connect", response_model=ConnectOut, dependencies=_auth)
async def connect(reg: Registry) -> ConnectOut:
    """Start Spotify authorization (PKCE). The device opens `authorize_url` in a browser; Spotify
    redirects to `/v1/music/callback`, which completes the exchange on the server."""
    client = _service(reg).spotify
    try:
        url, state, expires = await client.begin_authorization()
    except SpotifyError as exc:
        raise SpotifyNotConfigured() from exc
    return ConnectOut(authorize_url=url, state=state, expires_at=expires, redirect_uri=_redirect(reg))


@router.get("/callback", response_class=HTMLResponse)
async def callback(
    reg: Registry,
    code: str | None = None,
    state: str | None = None,
    error: str | None = Query(default=None, max_length=100),
) -> HTMLResponse:
    """Spotify's redirect target. No session token here: the single-use `state` created by an
    authenticated /connect call is what authorises the exchange."""
    if error:
        raise BadRequest("Spotify authorization was cancelled or refused.", code="spotify_denied")
    if not code or not state:
        raise BadRequest("The callback is missing its code or state.", code="callback_invalid")
    try:
        await _service(reg).spotify.complete_authorization(state, code)
    except SpotifyError as exc:
        if exc.kind == "not_configured":
            raise SpotifyNotConfigured() from exc
        if exc.kind in ("bad_request", "reauthorize"):
            raise BadRequest(
                "This Spotify sign-in link expired or was already used. Start again from ZORO.",
                code="callback_invalid",
            ) from exc
        raise Unavailable(
            "Spotify did not answer. Try connecting again.", code="spotify_unavailable"
        ) from exc
    return HTMLResponse(
        f"<!doctype html><meta charset=utf-8><title>ZORO</title><p>{escape('Spotify is connected. You can close this tab and return to ZORO.')}</p>"
    )


@router.post("/disconnect", status_code=204, dependencies=_auth)
async def disconnect(reg: Registry) -> None:
    await _service(reg).spotify.disconnect()


def spotify_status(client: SpotifyClient, connected: bool) -> SpotifyStatus:
    if not client.configured:
        return SpotifyStatus(state="not_configured", detail="Set SPOTIFY_CLIENT_ID on the server.")
    if client.reauth_needed:
        return SpotifyStatus(
            state="needs_reauthorization", detail="Spotify rejected the stored sign-in. Connect again."
        )
    if not connected:
        return SpotifyStatus(state="not_connected", detail="Connect Spotify from Integrations.")
    return SpotifyStatus(
        state="connected",
        detail="Signed in. Spotify checks Premium and the app's allowed-user list when playback is used.",
    )


@router.get("/status", response_model=MusicStatus, dependencies=_auth)
async def status(reg: Registry) -> MusicStatus:
    service = _service(reg)
    connected = await service.spotify.is_connected()
    provider = await service.provider() if service.spotify.configured or connected else "apple_music"
    return MusicStatus(
        spotify=spotify_status(service.spotify, connected),
        apple_music="Played by the device through device.music.control (needs a device online).",
        provider_in_use=provider,
        recommendations="Unavailable: Spotify removed recommendations for new apps; similar songs use search.",
    )


@router.get("/session", response_model=MusicSession, dependencies=_auth)
async def get_session(reg: Registry) -> MusicSession:
    return await _service(reg).session.get()


@router.put("/session", response_model=MusicSession)
async def put_session(body: MusicSessionUpdate, reg: Registry, device: CurrentDevice) -> MusicSession:
    """Devices tell the server what they are doing (provider, active device, last query) so the
    iPhone and the Mac see the same state."""
    return await _service(reg).session.update(body, actor=device.device_id)
