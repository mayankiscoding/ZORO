"""Alias of `app.core.settings` for callers that look for a `config` module."""

from app.core.settings import Settings, get_settings

__all__ = ["Settings", "get_settings"]
