"""Registers the research package: tools, intents, routes (/v1/research), capabilities."""

from __future__ import annotations

import re
from typing import Any

from fastapi import APIRouter, Depends

from app.api.deps import CurrentDevice, Registry
from app.core.types import AgentId, CapabilityStatus, IntegrationLevel
from app.research.fetch import SafeFetcher
from app.research.http import run_tool
from app.research.search import NoSearchProvider, SearchProvider
from app.research.tools import CompareIn, CompareOut, FetchIn, FetchOut, SearchIn, SearchOut, build_tools
from app.schemas.security import Capability
from app.tools.intents import IntentContext, IntentSpec

_URL = re.compile(r"https?://[^\s<>\"']+", re.I)
_SEARCH_PREFIX = re.compile(
    r"^(?:please\s+)?(?:search(?:\s+the)?\s+web\s+for|google|look\s+up|web\s+par\s+search\s+karo|"
    r"web\s+pe\s+dhundo|वेब\s+पर\s+खोजो|इंटरनेट\s+पर\s+खोजो)\s*",
    re.I,
)


def extract_url(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    match = _URL.search(text)
    return {"url": match.group(0).rstrip(".,)")} if match else None


def extract_search(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    query = _SEARCH_PREFIX.sub("", text.strip()).strip(" ?।")
    return {"query": query} if query and query != text.strip() else None


class _LazyShortlist:
    """Reads the shopping shortlist through its service at call time (the package may be absent)."""

    def __init__(self, reg: Any) -> None:
        self._reg = reg

    async def list(self) -> list[Any]:
        if not self._reg.has_service("shopping_shortlist"):
            return []
        return list(await self._reg.service("shopping_shortlist").list())


def build_router(require_device: Any) -> APIRouter:
    router = APIRouter(prefix="/research", tags=["research"], dependencies=[Depends(require_device)])

    async def _run(reg: Any, device: Any, name: str, args: Any) -> dict[str, Any]:
        run = await run_tool(reg, device.device_id, name, args, agent=AgentId.BROWSER_RESEARCH)
        return run.result or {}

    @router.post("/fetch", response_model=FetchOut)
    async def fetch(body: FetchIn, reg: Registry, device: CurrentDevice) -> dict[str, Any]:
        return await _run(reg, device, "research.fetch_url", body)

    @router.post("/search", response_model=SearchOut)
    async def search(body: SearchIn, reg: Registry, device: CurrentDevice) -> dict[str, Any]:
        return await _run(reg, device, "research.web_search", body)

    @router.post("/compare-shortlist", response_model=CompareOut)
    async def compare(body: CompareIn, reg: Registry, device: CurrentDevice) -> dict[str, Any]:
        return await _run(reg, device, "research.compare_shortlist", body)

    return router


def register(reg: Any, *, fetcher: SafeFetcher | None = None, search: SearchProvider | None = None) -> None:
    from app.api.deps import require_device

    fetcher = fetcher or SafeFetcher(clock=reg.service("clock"))
    search = search or NoSearchProvider()
    specs = build_tools(fetcher, search, _LazyShortlist(reg))
    for spec in specs:
        reg.add_tool(spec)
    reg.provide("research_fetcher", fetcher)
    reg.add_router(build_router(require_device))
    reg.add_intent(
        IntentSpec(
            name="research.fetch_url",
            agent=AgentId.BROWSER_RESEARCH,
            tool="research.fetch_url",
            keywords={
                "en": ["open this link", "read this page", "what does this page say"],
                "hi": ["यह लिंक पढ़ो", "यह पेज पढ़ो"],
                "hinglish": ["yeh link padho", "ye page padho"],
            },
            extract=extract_url,
            examples=("read this page https://example.org/a",),
        )
    )
    reg.add_intent(
        IntentSpec(
            name="research.web_search",
            agent=AgentId.BROWSER_RESEARCH,
            tool="research.web_search",
            keywords={
                "en": ["search the web for", "look up"],
                "hi": ["वेब पर खोजो", "इंटरनेट पर खोजो"],
                "hinglish": ["web par search karo", "web pe dhundo"],
            },
            extract=extract_search,
            examples=("search the web for monsoon trek gear",),
        )
    )
    reg.add_capability(
        Capability(
            id="research.fetch_url",
            title="Read public web pages",
            domain="research",
            status=CapabilityStatus.WORKING_LOCAL,
            integration_level=IntegrationLevel.FULLY_INTEGRATED,
            note="https only; private and metadata addresses are blocked.",
        )
    )
    reg.add_capability(
        lambda: Capability(
            id="research.web_search",
            title="Web search",
            domain="research",
            status=CapabilityStatus.WORKING_INTEGRATION
            if search.configured
            else CapabilityStatus.REQUIRES_CREDENTIALS,
            integration_level=IntegrationLevel.OFFICIAL_API
            if search.configured
            else IntegrationLevel.UNAVAILABLE,
            requires=[] if search.configured else ["a search API provider and its key"],
            note="No search provider is configured by default.",
        )
    )
