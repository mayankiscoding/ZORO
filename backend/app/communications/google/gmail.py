"""Gmail REST adapter (https://gmail.googleapis.com/gmail/v1/users/me).

`GmailClient.search(query, limit)` and `GmailClient.get(message_id)` are the surface the finance package
uses for receipts; threads, drafts and send serve the communications tools. Message content is
untrusted data: callers wrap it before any model sees it.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import re
from collections.abc import Callable
from datetime import UTC, datetime
from email.header import Header
from email.mime.text import MIMEText
from email.utils import parseaddr, parsedate_to_datetime
from html.parser import HTMLParser
from typing import Any

import httpx
from pydantic import BaseModel, ConfigDict, Field

from app.communications.google.oauth import GoogleError, GoogleOAuth

HttpFactory = Callable[[], httpx.AsyncClient]
_TIMEOUT = httpx.Timeout(20.0, connect=5.0)
MAX_RESULTS = 50
_ADDRESS = re.compile(r"^[^@\s<>,;\"']+@[^@\s<>,;\"']+\.[^@\s<>,;\"']+$")


class GmailAttachment(BaseModel):
    model_config = ConfigDict(extra="ignore")
    attachment_id: str
    filename: str
    mime_type: str
    size: int = 0


class GmailMessage(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: str
    thread_id: str
    sender: str = ""  # the From header as sent, "Name <addr>"
    to: list[str] = Field(default_factory=list)
    subject: str = ""
    date: datetime | None = None
    snippet: str = ""
    body_text: str = ""  # empty for search results (metadata only)
    body_html: str = ""
    attachments: list[GmailAttachment] = Field(default_factory=list)
    label_ids: list[str] = Field(default_factory=list)


class GmailDraftRef(BaseModel):
    draft_id: str
    message_id: str | None = None
    thread_id: str | None = None


class GmailSent(BaseModel):
    message_id: str
    thread_id: str | None = None


def valid_address(value: str) -> bool:
    return bool(_ADDRESS.match(value)) and len(value) <= 254


def build_raw(to: str, subject: str, body: str) -> str:
    """The base64url RFC 822 message. Body is UTF-8 and base64-encoded so it arrives exactly as written."""
    if not valid_address(to):
        raise ValueError("to must be a single email address")
    if "\r" in subject or "\n" in subject:
        raise ValueError("subject must be one line")
    msg = MIMEText(body, "plain", "utf-8")  # base64 of the UTF-8 bytes: the text arrives exactly as written
    msg["To"] = to
    msg["Subject"] = Header(subject, "utf-8").encode()
    return base64.urlsafe_b64encode(msg.as_bytes()).decode("ascii")


def _b64(data: str) -> bytes:
    try:
        return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
    except (binascii.Error, ValueError):
        return b""


class _Text(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self._skip = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in ("script", "style"):
            self._skip += 1
        elif tag in ("br", "p", "div", "tr", "li"):
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style") and self._skip:
            self._skip -= 1

    def handle_data(self, data: str) -> None:
        if not self._skip:
            self.parts.append(data)


def html_to_text(html: str) -> str:
    parser = _Text()
    parser.feed(html)
    text = "".join(parser.parts)
    return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t]+", " ", text)).strip()


def _walk(part: dict[str, Any], out: dict[str, Any]) -> None:
    mime = str(part.get("mimeType", ""))
    body = part.get("body") or {}
    filename = str(part.get("filename") or "")
    if filename and body.get("attachmentId"):
        out["attachments"].append(
            GmailAttachment(
                attachment_id=str(body["attachmentId"]),
                filename=filename,
                mime_type=mime,
                size=int(body.get("size", 0)),
            )
        )
    elif mime == "text/plain" and body.get("data"):
        out["text"].append(_b64(str(body["data"])).decode("utf-8", errors="replace"))
    elif mime == "text/html" and body.get("data"):
        out["html"].append(_b64(str(body["data"])).decode("utf-8", errors="replace"))
    for child in part.get("parts") or []:
        if isinstance(child, dict):
            _walk(child, out)


def parse_message(raw: dict[str, Any]) -> GmailMessage:
    payload = raw.get("payload") or {}
    headers = {
        str(h.get("name", "")).lower(): str(h.get("value", ""))
        for h in payload.get("headers") or []
        if isinstance(h, dict)
    }
    found: dict[str, Any] = {"text": [], "html": [], "attachments": []}
    if payload:
        _walk(payload, found)
    date: datetime | None = None
    if raw.get("internalDate"):
        try:
            date = datetime.fromtimestamp(int(raw["internalDate"]) / 1000, tz=UTC)
        except (ValueError, OverflowError, OSError):
            date = None
    if date is None and headers.get("date"):
        try:
            parsed = parsedate_to_datetime(headers["date"])
            date = parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
        except (TypeError, ValueError):
            date = None
    html = "\n".join(found["html"])
    text = "\n".join(found["text"]) or (html_to_text(html) if html else "")
    return GmailMessage(
        id=str(raw["id"]),
        thread_id=str(raw.get("threadId", raw["id"])),
        sender=headers.get("from", ""),
        to=[a.strip() for a in headers.get("to", "").split(",") if a.strip()],
        subject=headers.get("subject", ""),
        date=date,
        snippet=str(raw.get("snippet", "")),
        body_text=text,
        body_html=html,
        attachments=found["attachments"],
        label_ids=[str(x) for x in raw.get("labelIds") or []],
    )


def sender_address(sender: str) -> str:
    return parseaddr(sender)[1]


class GmailClient:
    def __init__(self, oauth: GoogleOAuth, http: HttpFactory) -> None:
        self._oauth = oauth
        self._http = http

    @property
    def base(self) -> str:
        return self._oauth.endpoints.gmail

    async def _request(
        self, method: str, path: str, *, params: Any = None, body: dict[str, Any] | None = None
    ) -> httpx.Response:
        token = await self._oauth.access_token()
        for attempt in (0, 1):
            try:
                async with self._http() as client:
                    response = await client.request(
                        method,
                        f"{self.base}{path}",
                        params=params,
                        json=body,
                        headers={"Authorization": f"Bearer {token}"},
                        timeout=_TIMEOUT,
                    )
            except httpx.HTTPError as exc:
                raise GoogleError("unavailable", "Gmail is unreachable") from exc
            if response.status_code == 401 and attempt == 0:
                token = await self._oauth.access_token(force_refresh=True)
                continue
            break
        if response.status_code == 401:
            await self._oauth.mark_expired()
            raise GoogleError("expired", "Gmail rejected the refreshed token")
        raise_for_gmail(response)
        return response

    # ------------------------------------------------------------ reading (finance uses search + get)

    async def search(self, query: str, limit: int = 10) -> list[GmailMessage]:
        """Messages matching a Gmail search query, newest first, as metadata (headers + snippet)."""
        params = {"q": query, "maxResults": max(1, min(limit, MAX_RESULTS))}
        listing = (await self._request("GET", "/messages", params=params)).json()
        ids = [str(m["id"]) for m in listing.get("messages") or [] if isinstance(m, dict) and m.get("id")]
        meta = [
            ("format", "metadata"),
            *[("metadataHeaders", h) for h in ("From", "To", "Subject", "Date")],
        ]
        responses = await asyncio.gather(*[self._request("GET", f"/messages/{i}", params=meta) for i in ids])
        return [parse_message(r.json()) for r in responses]

    async def get(self, message_id: str) -> GmailMessage:
        """One message in full: text body, HTML body and attachment descriptors."""
        raw = (await self._request("GET", f"/messages/{message_id}", params={"format": "full"})).json()
        return parse_message(raw)

    async def get_thread(self, thread_id: str) -> list[GmailMessage]:
        raw = (await self._request("GET", f"/threads/{thread_id}", params={"format": "full"})).json()
        return [parse_message(m) for m in raw.get("messages") or [] if isinstance(m, dict)]

    async def attachment(self, message_id: str, attachment_id: str) -> bytes:
        raw = (await self._request("GET", f"/messages/{message_id}/attachments/{attachment_id}")).json()
        return _b64(str(raw.get("data", "")))

    # ------------------------------------------------------------ writing

    async def create_draft(
        self, *, to: str, subject: str, body: str, thread_id: str | None = None
    ) -> GmailDraftRef:
        message: dict[str, Any] = {"raw": build_raw(to, subject, body)}
        if thread_id:
            message["threadId"] = thread_id
        data = (await self._request("POST", "/drafts", body={"message": message})).json()
        inner = data.get("message") or {}
        return GmailDraftRef(
            draft_id=str(data["id"]), message_id=inner.get("id"), thread_id=inner.get("threadId")
        )

    async def send(self, *, to: str, subject: str, body: str, thread_id: str | None = None) -> GmailSent:
        payload: dict[str, Any] = {"raw": build_raw(to, subject, body)}
        if thread_id:
            payload["threadId"] = thread_id
        data = (await self._request("POST", "/messages/send", body=payload)).json()
        return GmailSent(message_id=str(data["id"]), thread_id=data.get("threadId"))


def raise_for_gmail(response: httpx.Response) -> None:
    status = response.status_code
    if status < 400:
        return
    reason = ""
    try:
        errors = response.json().get("error", {}).get("errors") or []
        reason = str(errors[0].get("reason", "")) if errors else ""
    except (ValueError, AttributeError, IndexError):
        pass
    if status == 429 or (status == 403 and "ratelimit" in reason.lower()):
        retry = response.headers.get("retry-after", "")
        raise GoogleError("rate_limited", retry_after_s=int(retry) if retry.isdigit() else None)
    if status == 403:
        raise GoogleError("forbidden", reason or "insufficient permission")
    if status == 404:
        raise GoogleError("not_found")
    if status == 400:
        raise GoogleError("bad_request", reason)
    raise GoogleError("unavailable", f"Gmail status {status}")
