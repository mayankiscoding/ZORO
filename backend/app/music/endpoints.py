"""Spotify endpoints (verified against developer.spotify.com on 2026-11-13).

CLAUDE.md rule 7 wants provider URLs in config/*.yaml; this package does not own a yaml file, so the
defaults live here and are injectable. See change_requests in the stage report.
"""

from __future__ import annotations

from dataclasses import dataclass

#: Scopes: playback control and state, recently played, and playlist writes. Nothing else.
SCOPES = (
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "user-read-recently-played",
    "playlist-modify-private",
    "playlist-modify-public",
)


@dataclass(frozen=True)
class SpotifyEndpoints:
    authorize: str = "https://accounts.spotify.com/authorize"
    token: str = "https://accounts.spotify.com/api/token"  # noqa: S105 - a URL, not a secret
    api: str = "https://api.spotify.com/v1"
