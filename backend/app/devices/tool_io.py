"""Typed arguments and results of the device tools (docs/architecture/device-contract.md).

Arguments are validated on the backend before anything reaches a device, so a model cannot send a
malformed or out-of-contract action. Unknown keys are ignored (``extra="ignore"``), which lets slot
filling carry hints such as ``target_platform`` without breaking validation; they never reach the
digest or the device because only validated fields are dumped.
"""

from __future__ import annotations

import re
from datetime import date
from typing import Annotated, Literal
from urllib.parse import urlsplit

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator


class _In(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)


class _Out(BaseModel):
    model_config = ConfigDict(extra="ignore")


Title = Annotated[str, Field(min_length=1, max_length=200)]
Notes = Annotated[str, Field(max_length=2000)]
HHMM = Annotated[str, Field(pattern=r"^([01]\d|2[0-3]):[0-5]\d$")]
Weekday = Literal["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

_PHONE = re.compile(r"^[1-9]\d{7,14}$")
_PHONE_STRIP = re.compile(r"[\s\-().]")

#: App schemes `device.open_url` may open besides https. Everything else is refused here.
ALLOWED_APP_SCHEMES: frozenset[str] = frozenset(
    {"shortcuts", "music", "spotify", "maps", "calshow", "x-apple-reminderkit", "photos-redirect", "zoro"}
)


def normalise_phone(value: str) -> str:
    """International digits only (no '+', spaces or dashes), as `wa.me` and the composer expect."""
    digits = _PHONE_STRIP.sub("", value).removeprefix("+")
    if not _PHONE.match(digits):
        raise ValueError("phone must be an international number: country code and digits")
    return digits


# `device.health.query` metrics and the unit each one is reported in (device contract).
HEALTH_METRIC_UNITS: dict[str, str] = {
    "steps": "count",
    "walking_running_distance": "m",
    "cycling_distance": "m",
    "active_energy": "kcal",
    "exercise_minutes": "min",
    "heart_rate": "bpm",
    "resting_heart_rate": "bpm",
    "sleep": "min",
    "body_mass": "kg",
}
HealthMetric = Literal[
    "steps", "walking_running_distance", "cycling_distance", "active_energy", "exercise_minutes",
    "heart_rate", "resting_heart_rate", "sleep", "body_mass",
]  # fmt: skip
# Error codes a device may answer with (device contract); anything else is recorded as "failed".
DEVICE_ERROR_CODES = frozenset(
    {"permission_denied", "unsupported", "user_cancelled", "invalid_arguments", "expired", "failed"}
)
GEO_URI = r"^geo:-?\d{1,2}(\.\d+)?,-?\d{1,3}(\.\d+)?(;u=\d+(\.\d+)?)?$"  # RFC 5870, with uncertainty
# `<folder_ref>:<relative path>` inside a folder the owner approved; never an absolute path.
PATH_REF = r"^[A-Za-z0-9_-]{1,64}:[^/\\~\x00][^\x00]{0,399}$"


def _relative(value: str) -> str:
    relative = value.split(":", 1)[1]
    if ".." in relative.replace("\\", "/").split("/"):
        raise ValueError("path_ref must stay inside the approved folder")
    return value



# ---------------------------------------------------------------- calendar and reminders


class ReminderCreateIn(_In):
    title: Title
    due_at: AwareDatetime | None = None
    notes: Notes | None = None
    list_name: Annotated[str, Field(max_length=100)] | None = None


class CreatedOut(_Out):
    id: str


class EventCreateIn(_In):
    title: Title
    start_at: AwareDatetime
    end_at: AwareDatetime | None = None
    location: Annotated[str, Field(max_length=300)] | None = None
    notes: Notes | None = None
    calendar_name: Annotated[str, Field(max_length=100)] | None = None

    @model_validator(mode="after")
    def _end_after_start(self) -> EventCreateIn:
        if self.end_at is not None and self.end_at <= self.start_at:
            raise ValueError("end_at must be after start_at")
        return self


class UpcomingIn(_In):
    from_: AwareDatetime | None = Field(default=None, alias="from")
    to: AwareDatetime | None = None
    limit: int = Field(default=5, ge=1, le=50)

    model_config = ConfigDict(extra="ignore", populate_by_name=True, serialize_by_alias=True)


class CalendarEvent(_Out):
    id: str
    title: str
    start_at: AwareDatetime
    end_at: AwareDatetime
    location: str | None = None
    calendar: str


class UpcomingOut(_Out):
    events: list[CalendarEvent] = Field(default_factory=list)


# ---------------------------------------------------------------- contacts


class ContactsFindIn(_In):
    query: Annotated[str, Field(min_length=1, max_length=100)]


class ContactMatch(_Out):
    contact_ref: str
    name: str
    phones: list[str] = Field(default_factory=list)
    emails: list[str] = Field(default_factory=list)


class ContactsFindOut(_Out):
    matches: list[ContactMatch] = Field(default_factory=list)


class ContactSaveIn(_In):
    given_name: Annotated[str, Field(min_length=1, max_length=100)]
    family_name: Annotated[str, Field(max_length=100)] | None = None
    phone: str | None = None
    email: Annotated[str, Field(max_length=254, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")] | None = None

    @field_validator("phone")
    @classmethod
    def _phone(cls, value: str | None) -> str | None:
        return normalise_phone(value) if value else None


class ContactSaveOut(_Out):
    contact_ref: str


# ---------------------------------------------------------------- notifications, location, urls, shortcuts


class NotificationIn(_In):
    title: Title
    body: Annotated[str, Field(min_length=1, max_length=1000)]
    at: AwareDatetime | None = None


class LocationIn(_In):
    pass


class LocationOut(_Out):
    place_ref: Annotated[str, Field(pattern=GEO_URI)]  # e.g. "geo:12.97,77.59;u=65"
    locality: str | None = None
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    accuracy_m: float = Field(ge=0)


class OpenUrlIn(_In):
    url: Annotated[str, Field(min_length=4, max_length=2048)]

    @field_validator("url")
    @classmethod
    def _allowed(cls, value: str) -> str:
        parts = urlsplit(value)
        scheme = parts.scheme.lower()
        if scheme == "https":
            if not parts.netloc:
                raise ValueError("https URL needs a host")
            return value
        if scheme in ALLOWED_APP_SCHEMES:
            return value
        raise ValueError("url must be https or an allowlisted app scheme")


class OpenedOut(_Out):
    opened: bool


class ShortcutRunIn(_In):
    name: Annotated[str, Field(min_length=1, max_length=200)]
    input: Annotated[str, Field(max_length=4000)] | None = None


class StartedOut(_Out):
    started: bool


# ---------------------------------------------------------------- music, photos, health


class MusicControlIn(_In):
    # May be omitted: the device then picks the provider that is authorised and active, and names
    # it in the result (device contract, Clarifications).
    provider: Literal["apple_music", "spotify_app"] | None = None
    action: Literal["play", "pause", "next", "previous", "search_play"]
    query: Annotated[str, Field(max_length=200)] | None = None
    uri: Annotated[str, Field(max_length=300)] | None = None

    @model_validator(mode="after")
    def _search_needs_query(self) -> MusicControlIn:
        if self.action == "search_play" and not (self.query or self.uri):
            raise ValueError("search_play needs a query or a uri")
        return self


class NowPlaying(_Out):
    title: str
    artist: str
    provider: str


class MusicControlOut(_Out):
    now_playing: NowPlaying | None = None


class PhotoQuery(_In):
    text: Annotated[str, Field(max_length=500)] = ""
    date_from: date | None = None
    date_to: date | None = None
    colors: list[str] = Field(default_factory=list, max_length=10)
    labels: list[str] = Field(default_factory=list, max_length=20)
    contains_text: Annotated[str, Field(max_length=200)] | None = None
    media: Literal["photo", "screenshot", "any"] = "any"
    limit: int = Field(default=30, ge=1, le=200)


class PhotosSearchIn(_In):
    query: PhotoQuery


class PhotoHit(_Out):
    asset_id: str
    captured_at: AwareDatetime | None = None
    score: float
    labels: list[str] = Field(default_factory=list)
    matched: list[str] = Field(default_factory=list)


class PhotosSearchOut(_Out):
    hits: list[PhotoHit] = Field(default_factory=list)
    indexed_count: int = Field(ge=0)
    limited_library: bool = False


class HealthQueryIn(_In):
    metric: HealthMetric
    from_: AwareDatetime = Field(alias="from")
    to: AwareDatetime
    bucket: Literal["day", "week"] = "day"

    model_config = ConfigDict(extra="ignore", populate_by_name=True, serialize_by_alias=True)

    @model_validator(mode="after")
    def _range(self) -> HealthQueryIn:
        if self.to <= self.from_:
            raise ValueError("to must be after from")
        return self


class HealthPoint(_Out):
    start: AwareDatetime
    value: float
    unit: str


class HealthQueryOut(_Out):
    points: list[HealthPoint] = Field(default_factory=list)
    sources: list[str] = Field(default_factory=list)
    latest_sample_at: AwareDatetime | None = None


# ---------------------------------------------------------------- composers (the owner taps send)


class WhatsAppComposeIn(_In):
    phone: str | None = None
    text: Annotated[str, Field(min_length=1, max_length=4000)]
    # Shown in the approval next to the number; the device does not need it to open the composer.
    recipient_name: Annotated[str, Field(max_length=200)] | None = None

    @field_validator("phone")
    @classmethod
    def _phone(cls, value: str | None) -> str | None:
        return normalise_phone(value) if value else None


class MessageComposeIn(_In):
    recipients: list[str] = Field(min_length=1, max_length=20)
    body: Annotated[str, Field(min_length=1, max_length=4000)]
    recipient_name: Annotated[str, Field(max_length=200)] | None = None  # shown in the approval

    @field_validator("recipients")
    @classmethod
    def _phones(cls, values: list[str]) -> list[str]:
        return [normalise_phone(v) for v in values]


class MessageComposeOut(_Out):
    presented: bool
    sent: bool | None = None


# ---------------------------------------------------------------- iPhone only


class AlarmCreateIn(_In):
    time: HHMM
    label: Annotated[str, Field(max_length=100)] | None = None
    repeat_days: list[Weekday] | None = Field(default=None, max_length=7)


class AlarmCreateOut(_Out):
    alarm_id: str


class TimerStartIn(_In):
    seconds: int = Field(ge=1, le=24 * 60 * 60)
    label: Annotated[str, Field(max_length=100)] | None = None


class TimerStartOut(_Out):
    timer_id: str


class HomeSceneIn(_In):
    scene_name: Annotated[str, Field(min_length=1, max_length=100)]


class RanOut(_Out):
    ran: bool


# ---------------------------------------------------------------- Mac only


class AppleScriptRunIn(_In):
    script_id: Annotated[str, Field(pattern=r"^[a-z0-9][a-z0-9_.-]{0,63}$")]
    params: dict[str, str | int | bool] | None = Field(default=None, max_length=20)


class AppleScriptRunOut(_Out):
    output: str | None = None


class FileSearchIn(_In):
    query: Annotated[str, Field(min_length=1, max_length=200)]
    folder_ref: Annotated[str, Field(max_length=200)] | None = None


class FileHit(_Out):
    path_ref: Annotated[str, Field(pattern=PATH_REF)]
    name: str
    modified_at: AwareDatetime | None = None


class FileSearchOut(_Out):
    files: list[FileHit] = Field(default_factory=list)


class FileOpenIn(_In):
    path_ref: Annotated[str, Field(pattern=PATH_REF)]

    @field_validator("path_ref")
    @classmethod
    def _inside_folder(cls, value: str) -> str:
        return _relative(value)
