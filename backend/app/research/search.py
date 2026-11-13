"""Web search behind an interface. No search provider is configured by default and none is invented:
until one is wired in with real credentials, search reports "requires_credentials"."""

from __future__ import annotations

from datetime import datetime
from typing import Protocol

from pydantic import BaseModel


class SearchHit(BaseModel):
    title: str
    url: str
    snippet: str = ""
    source: str  # the search provider
    retrieved_at: datetime


class SearchUnavailable(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class SearchProvider(Protocol):
    name: str

    @property
    def configured(self) -> bool: ...

    async def search(self, query: str, *, limit: int = 5) -> list[SearchHit]: ...


class NoSearchProvider:
    """The default: honest absence."""

    name = "none"

    @property
    def configured(self) -> bool:
        return False

    async def search(self, query: str, *, limit: int = 5) -> list[SearchHit]:
        raise SearchUnavailable("requires_credentials")
