"""`/v1/communications`: drafts, and Gmail connect / callback / status / disconnect."""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Query
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field
from starlette.responses import HTMLResponse

from app.api.deps import Registry, require_device
from app.communications.google.endpoints import SCOPES, UNVERIFIED_REFRESH_DAYS
from app.communications.google.oauth import GoogleError
from app.communications.schemas import Channel, DraftStatus, DraftView
from app.communications.service import CommunicationService
from app.core.errors import BadRequest, Unavailable
from app.schemas.common import Page

router = APIRouter(prefix="/communications", tags=["communications"])
_auth = [Depends(require_device)]


class GmailNotConfigured(Unavailable):
    code = "requires_credentials"
    retryable = False
    default_message = "Gmail needs GOOGLE_OAUTH_CLIENT_ID (and GOOGLE_OAUTH_CLIENT_SECRET for a desktop client) on the server."


class _Body(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)


class DraftEdit(_Body):
    text: Annotated[str, Field(min_length=1, max_length=20000)] | None = None
    subject: Annotated[str, Field(min_length=1, max_length=200)] | None = None


class GmailConnectOut(_Body):
    authorize_url: str
    state: str
    expires_at: AwareDatetime
    redirect_uri: str
    scopes: list[str]


class GmailStatus(_Body):
    state: Literal["not_configured", "not_connected", "connected", "expired"]
    detail: str
    connected_at: AwareDatetime | None = None
    expired_at: AwareDatetime | None = None
    refresh_expiry_hint_at: AwareDatetime | None = None  # connected_at + 7 days; only unverified apps


def _service(reg: Registry) -> CommunicationService:
    service: CommunicationService = reg.service("communications")
    return service


def _redirect(reg: Registry) -> str:
    return f"{str(reg.service('settings').public_base_url).rstrip('/')}/v1/communications/gmail/callback"


# ---------------------------------------------------------------- drafts


@router.get("/drafts", response_model=Page[DraftView], dependencies=_auth)
async def list_drafts(
    reg: Registry,
    status: DraftStatus | None = None,
    channel: Channel | None = None,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> Page[DraftView]:
    offset = int(cursor) if cursor and cursor.isdigit() else 0
    items, next_offset = await _service(reg).drafts.list_drafts(
        status=status, channel=channel, limit=limit, offset=offset
    )
    return Page[DraftView](items=items, next_cursor=None if next_offset is None else str(next_offset))


@router.get("/drafts/{draft_id}", response_model=DraftView, dependencies=_auth)
async def get_draft(draft_id: str, reg: Registry) -> DraftView:
    return await _service(reg).drafts.get(draft_id)


@router.patch("/drafts/{draft_id}", response_model=DraftView, dependencies=_auth)
async def edit_draft(draft_id: str, body: DraftEdit, reg: Registry) -> DraftView:
    """Edit an open draft. Editing never sends anything; sending always needs an approval."""
    if body.text is None and body.subject is None:
        raise BadRequest("Send a new text or subject.", code="nothing_to_change")
    return await _service(reg).drafts.edit(draft_id, text=body.text, subject=body.subject)


@router.delete("/drafts/{draft_id}", response_model=DraftView, dependencies=_auth)
async def discard_draft(draft_id: str, reg: Registry) -> DraftView:
    return await _service(reg).drafts.discard(draft_id)


# ---------------------------------------------------------------- Gmail connection


@router.post("/gmail/connect", response_model=GmailConnectOut, dependencies=_auth)
async def gmail_connect(reg: Registry) -> GmailConnectOut:
    """Start Google sign-in (authorization code + PKCE). The device opens `authorize_url`; Google
    redirects to `/gmail/callback`, which completes the exchange on the server."""
    try:
        url, state, expires = await _service(reg).oauth.begin_authorization()
    except GoogleError as exc:
        raise GmailNotConfigured() from exc
    return GmailConnectOut(
        authorize_url=url, state=state, expires_at=expires, redirect_uri=_redirect(reg), scopes=list(SCOPES)
    )


@router.get("/gmail/callback", response_class=HTMLResponse)
async def gmail_callback(
    reg: Registry,
    code: str | None = None,
    state: str | None = None,
    error: str | None = Query(default=None, max_length=100),
) -> HTMLResponse:
    """Google's redirect target. No session token: the single-use `state` made by an authenticated
    /gmail/connect call authorises the exchange."""
    if error:
        raise BadRequest("Google sign-in was cancelled or refused.", code="google_denied")
    if not code or not state:
        raise BadRequest("The callback is missing its code or state.", code="callback_invalid")
    try:
        await _service(reg).oauth.complete_authorization(state, code)
    except GoogleError as exc:
        if exc.kind == "not_configured":
            raise GmailNotConfigured() from exc
        if exc.kind in ("bad_request", "expired"):
            raise BadRequest(
                "This Google sign-in link expired, was already used, or returned no offline access. "
                "Start again from ZORO.",
                code="callback_invalid",
            ) from exc
        raise Unavailable("Google did not answer. Try connecting again.", code="google_unavailable") from exc
    return HTMLResponse(
        "<!doctype html><meta charset=utf-8><title>ZORO</title>"
        "<p>Gmail is connected. You can close this tab and return to ZORO.</p>"
    )


@router.get("/gmail/status", response_model=GmailStatus, dependencies=_auth)
async def gmail_status(reg: Registry) -> GmailStatus:
    oauth = _service(reg).oauth
    state = await oauth.state()
    details = {
        "not_configured": "Set GOOGLE_OAUTH_CLIENT_ID on the server.",
        "not_connected": "Connect Gmail from Integrations.",
        "connected": (
            "Signed in. If your Google app is unverified (Testing), Google ends the sign-in after "
            f"{UNVERIFIED_REFRESH_DAYS} days and you will need to connect again."
        ),
        "expired": "Your Google sign-in expired or was revoked. Connect Gmail again.",
    }
    return GmailStatus(
        state=state.state,
        detail=details[state.state],
        connected_at=state.connected_at,
        expired_at=state.expired_at,
        refresh_expiry_hint_at=state.refresh_expiry_hint_at if state.state == "connected" else None,
    )


@router.post("/gmail/disconnect", status_code=200, dependencies=_auth)
async def gmail_disconnect(reg: Registry) -> dict[str, bool]:
    """Revoke at Google (best effort) and forget the tokens here."""
    return {"revoked_at_google": await _service(reg).oauth.disconnect()}
