"""Google endpoints and scopes. CLAUDE.md rule 7 wants provider URLs in config/*.yaml; this package does
not own a yaml file, so the defaults live here and are injectable (see change_requests)."""

from __future__ import annotations

from dataclasses import dataclass

#: Read mail and create drafts / send. Both are restricted scopes: an unverified app can use them only
#: for test users, and its refresh tokens then expire after 7 days (surfaced as the "expired" state).
SCOPES = (
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.compose",
)
UNVERIFIED_REFRESH_DAYS = 7


@dataclass(frozen=True)
class GoogleEndpoints:
    authorize: str = "https://accounts.google.com/o/oauth2/v2/auth"
    token: str = "https://oauth2.googleapis.com/token"  # noqa: S105 - a URL, not a secret
    revoke: str = "https://oauth2.googleapis.com/revoke"
    gmail: str = "https://gmail.googleapis.com/gmail/v1/users/me"
