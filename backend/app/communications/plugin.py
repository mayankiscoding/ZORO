"""Registers the communications package: Google OAuth + Gmail, drafts, tools, intents, routes, capabilities."""

from __future__ import annotations

import os
from collections.abc import Mapping
from typing import Any

import httpx

from app.communications.api import router
from app.communications.drafts import DraftStore
from app.communications.google.gmail import GmailClient
from app.communications.google.oauth import GoogleOAuth
from app.communications.intents import communication_intents
from app.communications.service import CommunicationService
from app.communications.tools import PERMISSIONS, build_tools
from app.core.types import CapabilityStatus, IntegrationLevel
from app.schemas.security import Capability


def communication_capabilities(oauth: GoogleOAuth) -> list[Capability]:
    if not oauth.configured:
        state = "not_configured"
    else:  # the hint is only trusted for the states that need a token
        state = oauth.state_hint if oauth.state_hint in ("connected", "expired") else "not_connected"
    if state == "not_configured":
        gmail = Capability(
            id="communications.gmail", title="Gmail (search, read, draft, send)", domain="communications",
            status=CapabilityStatus.REQUIRES_CREDENTIALS, integration_level=IntegrationLevel.OFFICIAL_API,
            requires=["GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"],
            note="Create a Google Cloud OAuth client (desktop app) and enable the Gmail API.",
        )  # fmt: skip
    elif state == "connected":
        gmail = Capability(
            id="communications.gmail", title="Gmail (search, read, draft, send)", domain="communications",
            status=CapabilityStatus.WORKING_INTEGRATION, integration_level=IntegrationLevel.OFFICIAL_API,
            note="Sending always needs your approval. An unverified Google app signs you out after 7 days.",
        )  # fmt: skip
    else:
        gmail = Capability(
            id="communications.gmail", title="Gmail (search, read, draft, send)", domain="communications",
            status=CapabilityStatus.MANUAL_USER_STEP, integration_level=IntegrationLevel.OFFICIAL_API,
            requires=["Connect Gmail from Integrations"],
            note="Signed out." if state == "not_connected" else "Google sign-in expired or was revoked: connect again.",
        )  # fmt: skip
    return [
        gmail,
        Capability(
            id="communications.whatsapp",
            title="WhatsApp message handoff",
            domain="communications",
            status=CapabilityStatus.MANUAL_USER_STEP,
            integration_level=IntegrationLevel.DEEP_LINK_HANDOFF,
            requires=["a paired device online"],
            note="Opens WhatsApp with the text (wa.me / device.whatsapp.compose); you tap send. "
            "The WhatsApp Cloud API needs a business account and is not used.",
        ),
        Capability(
            id="communications.sms",
            title="SMS and iMessage handoff",
            domain="communications",
            status=CapabilityStatus.RESTRICTED_BY_IOS,
            integration_level=IntegrationLevel.DEEP_LINK_HANDOFF,
            requires=["a paired iPhone online"],
            note="The Messages composer always needs your tap on send; iMessage has no separate API.",
        ),
    ]


def install(
    reg: Any, *, env: Mapping[str, str] | None = None, http: Any = None, endpoints: Any = None
) -> CommunicationService:
    environment: Mapping[str, str] = env if env is not None else os.environ
    settings = reg.service("settings")
    factory = http or (lambda: httpx.AsyncClient(timeout=httpx.Timeout(20.0, connect=5.0)))
    oauth = GoogleOAuth(
        secrets=reg.service("secrets"),
        clock=reg.service("clock"),
        http=factory,
        client_id=lambda: environment.get("GOOGLE_OAUTH_CLIENT_ID", "").strip() or None,
        client_secret=lambda: environment.get("GOOGLE_OAUTH_CLIENT_SECRET", "").strip() or None,
        redirect_uri=lambda: f"{str(settings.public_base_url).rstrip('/')}/v1/communications/gmail/callback",
        endpoints=endpoints,
    )
    gmail = GmailClient(oauth, factory)
    service = CommunicationService(
        drafts=DraftStore(reg.service("session_factory"), reg.service("cipher"), reg.service("clock")),
        gmail=gmail,
        oauth=oauth,
    )
    reg.provide("communications", service)
    reg.provide("google_oauth", oauth)
    reg.provide("gmail", gmail)  # finance reads receipts with gmail.search(query, limit) / gmail.get(id)
    for key, title, default in PERMISSIONS:
        reg.add_permission(key, title, default)
    for spec in build_tools(service):
        reg.add_tool(spec)
    for intent in communication_intents():
        reg.add_intent(intent)
    reg.add_router(router)
    reg.add_capability(lambda: communication_capabilities(oauth))
    reg.add_startup(oauth.state)
    return service


def register(reg: Any) -> None:
    install(reg)
