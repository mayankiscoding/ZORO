"""Typed inputs and outputs for the communications tools and routers."""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

from app.communications.google.gmail import valid_address
from app.communications.recipients import Candidate
from app.tools.followup import FollowUp

Channel = Literal["whatsapp", "sms", "imessage", "email"]
MessageChannel = Literal["whatsapp", "sms", "imessage"]
DraftStatus = Literal["draft", "sent", "handed_off", "discarded"]
GmailStatus = Literal[
    "ok",
    "not_configured",
    "not_connected",
    "expired",
    "forbidden",
    "rate_limited",
    "not_found",
    "unavailable",
]
Language = Literal["en", "hi", "hinglish"]


class _In(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)


class _Out(BaseModel):
    model_config = ConfigDict(extra="ignore")


def _one_line(value: str) -> str:
    if "\r" in value or "\n" in value:
        raise ValueError("must be a single line")
    return value


class DraftView(_Out):
    id: str
    channel: Channel
    recipient_ref: str | None = None
    recipient_display: str
    recipient_address: str  # phone digits or email address
    subject: str | None = None
    text: str
    language: Language
    status: DraftStatus
    external_id: str | None = None
    created_at: AwareDatetime
    updated_at: AwareDatetime
    sent_at: AwareDatetime | None = None


# ---------------------------------------------------------------- draft_message


class ContactIn(_In):
    contact_ref: str | None = None
    name: str
    phones: list[str] = Field(default_factory=list)
    emails: list[str] = Field(default_factory=list)


class DraftMessageIn(_In):
    channel: Channel
    text: Annotated[str, Field(min_length=1, max_length=4000)]
    subject: Annotated[str, Field(max_length=200)] | None = None
    recipient_query: Annotated[str, Field(max_length=100)] | None = None  # a name
    recipient: Annotated[str, Field(max_length=254)] | None = None  # an address or number the owner gave
    contacts: list[ContactIn] | None = None  # device.contacts.find matches for recipient_query
    # True when the owner asked to send (not only to draft): a prepared draft then hands over the
    # send step, which always waits for the owner's approval.
    send: bool = False
    choice: int | None = Field(default=None, ge=1, le=20)  # "the second one" after a clarification

    @field_validator("subject")
    @classmethod
    def _subject(cls, value: str | None) -> str | None:
        return None if value is None else _one_line(value)


class DraftMessageOut(_Out):
    status: Literal[
        "prepared", "needs_recipient", "needs_contact_lookup", "ambiguous", "no_contact", "invalid"
    ]
    draft: DraftView | None = None
    candidates: list[Candidate] = Field(default_factory=list)
    # Next steps for the orchestrator (`app.tools.followup`): the contact lookup on the device
    # and the retry with its matches, or the approval-gated send of a prepared draft.
    follow_ups: list[FollowUp] = Field(default_factory=list)
    query: str | None = None
    message: str = ""


# ---------------------------------------------------------------- email (Gmail)


class FindEmailIn(_In):
    query: Annotated[str, Field(min_length=1, max_length=300)]  # Gmail search syntax
    limit: int = Field(default=5, ge=1, le=20)


class EmailSummary(_Out):
    id: str
    thread_id: str
    sender: str
    subject: str
    date: AwareDatetime | None = None
    snippet: str = ""


class FindEmailOut(_Out):
    status: GmailStatus
    query: str = ""
    emails: list[EmailSummary] = Field(default_factory=list)


class ThreadRef(_In):
    thread_id: Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{2,64}$")] | None = None
    ref: int | None = Field(default=None, ge=1, le=20)  # "the second email" from the last search

    @model_validator(mode="after")
    def _need_one(self) -> ThreadRef:
        if self.thread_id is None and self.ref is None:
            raise ValueError("give thread_id or ref")
        return self


class ThreadMessage(_Out):
    id: str
    sender: str
    to: list[str] = Field(default_factory=list)
    date: AwareDatetime | None = None
    body: str = ""
    attachments: list[str] = Field(default_factory=list)  # file names only


class ReadThreadOut(_Out):
    status: GmailStatus
    thread_id: str | None = None
    subject: str = ""
    messages: list[ThreadMessage] = Field(default_factory=list)
    truncated: bool = False


class SummarizeThreadOut(_Out):
    status: GmailStatus
    thread_id: str | None = None
    subject: str = ""
    message_count: int = 0
    summary: str = ""
    via: Literal["model", "excerpt", "none"] = "none"  # excerpt: no model was permitted, deterministic
    model: str | None = None


class EmailDraftIn(_In):
    to: Annotated[str, Field(min_length=3, max_length=254)]
    subject: Annotated[str, Field(min_length=1, max_length=200)]
    body: Annotated[str, Field(min_length=1, max_length=20000)]
    draft_id: Annotated[str, Field(max_length=40)] | None = None
    thread_id: Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{2,64}$")] | None = None

    @field_validator("to", "subject")
    @classmethod
    def _line(cls, value: str) -> str:
        return _one_line(value)

    @field_validator("to")
    @classmethod
    def _address(cls, value: str) -> str:
        if not valid_address(value):
            raise ValueError("to must be one email address")
        return value.lower()


class EmailDraftOut(_Out):
    status: GmailStatus
    gmail_draft_id: str | None = None
    draft_id: str | None = None
    to: str = ""
    subject: str = ""


class SendEmailIn(_In):
    draft_id: Annotated[str, Field(min_length=4, max_length=40)]
    to: Annotated[str, Field(min_length=3, max_length=254)]
    display_name: Annotated[str, Field(max_length=200)] = ""  # shown in the approval
    subject: Annotated[str, Field(min_length=1, max_length=200)]
    body: Annotated[str, Field(min_length=1, max_length=20000)]
    thread_id: Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{2,64}$")] | None = None

    @field_validator("to", "subject", "display_name")
    @classmethod
    def _line(cls, value: str) -> str:
        return _one_line(value)

    @field_validator("to")
    @classmethod
    def _address(cls, value: str) -> str:
        if not valid_address(value):
            raise ValueError("to must be one email address")
        return value.lower()


class SendEmailOut(_Out):
    status: Literal["sent", "draft_mismatch", "not_configured", "not_connected", "expired", "forbidden",
                    "rate_limited", "not_found", "unavailable"]  # fmt: skip
    to: str = ""
    subject: str = ""
    gmail_message_id: str | None = None


# ---------------------------------------------------------------- send_message (compose handoff)


class SendMessageIn(_In):
    draft_id: Annotated[str, Field(min_length=4, max_length=40)]
    channel: MessageChannel
    recipient_display: Annotated[str, Field(min_length=1, max_length=200)]
    phone: Annotated[str, Field(pattern=r"^[1-9]\d{7,14}$")]  # international digits
    text: Annotated[str, Field(min_length=1, max_length=4000)]


class SendMessageOut(_Out):
    status: Literal["handed_off", "draft_mismatch"]
    channel: MessageChannel
    recipient_display: str = ""
    phone: str = ""
    link: str | None = None  # https://wa.me/<digits>?text=... (WhatsApp)
    follow_ups: list[FollowUp] = Field(default_factory=list)  # the device composer to open
    note: str = ""
