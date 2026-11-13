"""Short alias of `app.api.dependencies`."""

from app.api.dependencies import (
    CurrentDevice,
    DbSession,
    Registry,
    bearer_token,
    block_when_killed,
    get_registry,
    get_session,
    require_device,
)

__all__ = [
    "CurrentDevice",
    "DbSession",
    "Registry",
    "bearer_token",
    "block_when_killed",
    "get_registry",
    "get_session",
    "require_device",
]
