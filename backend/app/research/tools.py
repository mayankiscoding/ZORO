"""Research tools: research.fetch_url, research.web_search, research.compare_shortlist."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field

from app.core.types import AgentId, DataClass, RiskLevel
from app.research.fetch import FetchError, SafeFetcher
from app.research.product_compare import ProductComparison, compare_products
from app.research.search import SearchHit, SearchProvider, SearchUnavailable
from app.schemas.common import UICard
from app.tools.spec import ToolContext, ToolSpec

MCP_GROUP = "browser-research-mcp"
AGENTS = frozenset({AgentId.BROWSER_RESEARCH, AgentId.PRODUCT_RESEARCH, AgentId.PERSONAL_ASSISTANT})


class FetchIn(BaseModel):
    url: str = Field(min_length=8, max_length=2000)
    max_chars: int = Field(default=20_000, ge=500, le=100_000)


class FetchOut(BaseModel):
    status: Literal["ok", "error"]
    url: str
    final_url: str | None = None
    title: str = ""
    text: str = ""
    content_type: str | None = None
    truncated: bool = False
    retrieved_at: datetime | None = None
    error: str | None = None


class SearchIn(BaseModel):
    query: str = Field(min_length=1, max_length=300)
    limit: int = Field(default=5, ge=1, le=10)


class SearchOut(BaseModel):
    status: Literal["ok", "unavailable"]
    query: str
    provider: str
    hits: list[SearchHit] = Field(default_factory=list)
    reason: str | None = None


class CompareIn(BaseModel):
    entry_ids: list[str] | None = None  # None: the whole shortlist


class CompareOut(BaseModel):
    status: Literal["ok", "unavailable", "empty"]
    comparison: ProductComparison | None = None
    reason: str | None = None


def sources_card(items: list[dict[str, Any]], title: str) -> UICard | None:
    return UICard(kind="sources", title=title, payload={"sources": items}) if items else None


def _fetch_summary(r: FetchOut, lang: str) -> str:
    if r.status == "error":
        return {"hi": f"पेज नहीं खुला: {r.error}।", "hinglish": f"Page nahi khula: {r.error}."}.get(
            lang, f"Could not read the page: {r.error}."
        )
    name = r.title or r.final_url or r.url
    return {"hi": f"पेज पढ़ लिया: {name}।", "hinglish": f"Page padh liya: {name}."}.get(
        lang, f"Read the page: {name}."
    )


def _search_summary(r: SearchOut, lang: str) -> str:
    if r.status == "unavailable":
        return {
            "hi": "वेब सर्च अभी सेट नहीं है।",
            "hinglish": "Web search abhi set up nahi hai.",
        }.get(lang, "Web search is not set up yet.")
    n = len(r.hits)
    return {"hi": f"{n} परिणाम मिले।", "hinglish": f"{n} results mile."}.get(lang, f"Found {n} results.")


def _compare_summary(r: CompareOut, lang: str) -> str:
    if r.comparison is None:
        return {"hi": "शॉर्टलिस्ट खाली है।", "hinglish": "Shortlist khaali hai."}.get(
            lang, "The shortlist is empty."
        )
    n, rows = len(r.comparison.products), len(r.comparison.rows)
    return {
        "hi": f"{n} उत्पादों की {rows} बातों पर तुलना की।",
        "hinglish": f"{n} products ko {rows} points par compare kiya.",
    }.get(lang, f"Compared {n} products on {rows} attributes.")


def build_tools(fetcher: SafeFetcher, search: SearchProvider, shortlist: Any | None) -> list[ToolSpec]:
    async def fetch_url(ctx: ToolContext, args: FetchIn) -> FetchOut:
        try:
            page = await fetcher.fetch(args.url)
        except FetchError as exc:
            return FetchOut(status="error", url=args.url, error=exc.code)
        return FetchOut(
            status="ok",
            url=args.url,
            final_url=page.final_url,
            title=page.title,
            text=page.text[: args.max_chars],
            content_type=page.content_type,
            truncated=page.truncated or len(page.text) > args.max_chars,
            retrieved_at=page.retrieved_at,
        )

    async def web_search(ctx: ToolContext, args: SearchIn) -> SearchOut:
        if not search.configured:
            return SearchOut(
                status="unavailable", query=args.query, provider=search.name, reason="requires_credentials"
            )
        try:
            hits = await search.search(args.query, limit=args.limit)
        except SearchUnavailable as exc:
            return SearchOut(status="unavailable", query=args.query, provider=search.name, reason=exc.reason)
        return SearchOut(status="ok", query=args.query, provider=search.name, hits=hits[: args.limit])

    async def compare_shortlist(ctx: ToolContext, args: CompareIn) -> CompareOut:
        if shortlist is None:
            return CompareOut(status="unavailable", reason="shortlist_not_available")
        entries = await shortlist.list()
        if args.entry_ids is not None:
            entries = [e for e in entries if e.entry_id in set(args.entry_ids)]
        if not entries:
            return CompareOut(status="empty")
        return CompareOut(status="ok", comparison=compare_products(entries))

    def fetch_card(r: FetchOut) -> UICard | None:
        if r.status != "ok":
            return None
        item = {
            "url": r.final_url or r.url,
            "title": r.title,
            "retrieved_at": r.retrieved_at.isoformat() if r.retrieved_at else None,
        }
        return sources_card([item], "Sources")

    def search_card(r: SearchOut) -> UICard | None:
        return sources_card(
            [{"url": h.url, "title": h.title, "retrieved_at": h.retrieved_at.isoformat()} for h in r.hits],
            r.query,
        )

    def compare_card(r: CompareOut) -> UICard | None:
        if r.comparison is None:
            return None
        return sources_card(
            [
                {
                    "url": p.url,
                    "title": p.name,
                    "retrieved_at": p.retrieved_at.isoformat(),
                    "source": p.source,
                }
                for p in r.comparison.products
            ],
            "Product comparison sources",
        )

    public = frozenset({DataClass.PUBLIC})
    return [
        ToolSpec(
            name="research.fetch_url",
            description="Fetch a public https page and return its text (untrusted).",
            input_model=FetchIn,
            output_model=FetchOut,
            handler=fetch_url,
            risk=RiskLevel.LOW,
            data_classes=public,
            permission=None,
            agents=AGENTS,
            mcp_group=MCP_GROUP,
            untrusted_output=True,
            timeout_s=25,
            rate_limit_per_min=20,
            summarizer=_fetch_summary,
            card=fetch_card,
        ),
        ToolSpec(
            name="research.web_search",
            description="Search the web through the configured search provider.",
            input_model=SearchIn,
            output_model=SearchOut,
            handler=web_search,
            risk=RiskLevel.LOW,
            data_classes=public,
            permission=None,
            agents=AGENTS,
            mcp_group=MCP_GROUP,
            untrusted_output=True,
            timeout_s=20,
            rate_limit_per_min=20,
            summarizer=_search_summary,
            card=search_card,
        ),
        ToolSpec(
            name="research.compare_shortlist",
            description="Compare shortlisted products using only the specifications their sources gave.",
            input_model=CompareIn,
            output_model=CompareOut,
            handler=compare_shortlist,
            risk=RiskLevel.LOW,
            data_classes=frozenset({DataClass.PERSONAL}),
            permission=None,
            agents=AGENTS | {AgentId.SHOPPING},
            mcp_group=MCP_GROUP,
            summarizer=_compare_summary,
            card=compare_card,
        ),
    ]
