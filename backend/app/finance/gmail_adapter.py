"""Adapts the communications package's Gmail client (service ``gmail``) to the small
`GmailClient` interface the receipt connector reads through. Resolved lazily at call time, so
plugin load order does not matter."""

from __future__ import annotations

from typing import Any

from app.core.errors import Unavailable
from app.finance.connectors import GmailMessage, GmailMessageRef


class CommunicationsGmail:
    def __init__(self, gmail: Any) -> None:
        self._gmail = gmail  # app.communications.google.gmail.GmailClient

    async def _call(self, fn: Any, *args: Any) -> Any:
        try:
            return await fn(*args)
        except Exception as exc:
            kind = getattr(exc, "kind", None)  # GoogleError: not_configured, not_connected, expired, ...
            if kind is None:
                raise
            code = (
                "requires_credentials"
                if kind in ("not_configured", "not_connected", "expired")
                else str(kind)
            )
            raise Unavailable("Gmail is not available right now.", code=code) from exc

    async def search(self, query: str, *, max_results: int = 50) -> list[GmailMessageRef]:
        found = await self._call(self._gmail.search, query, max_results)
        # A message without a Date header cannot be placed on a day; it is left out, not guessed.
        return [GmailMessageRef(id=m.id, thread_id=m.thread_id) for m in found if m.date is not None]

    async def get(self, message_id: str) -> GmailMessage:
        m = await self._call(self._gmail.get, message_id)
        if m.date is None:
            raise Unavailable("This email has no date.", code="malformed_message")
        return GmailMessage(
            id=m.id, received_at=m.date, sender=m.sender, subject=m.subject, text=m.body_text or m.snippet
        )
