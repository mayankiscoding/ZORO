"""Memory tools: memory.remember (MEDIUM), memory.search (LOW, read-only), memory.forget (MEDIUM)."""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, model_validator

from app.core.errors import NotFound
from app.core.types import AgentId, DataClass, MemoryCategory, RiskLevel
from app.memory.access import ALL_BUT_SECRET
from app.memory.classify import classify, max_sensitivity
from app.memory.proposals import source_for
from app.memory.service import MemoryService
from app.memory.types import AddResult
from app.schemas.common import LabelValue, UICard
from app.schemas.data import MemoryRecord
from app.tools.spec import ApprovalView, ToolContext, ToolSpec

MEMORY_CLASSES = frozenset({DataClass.PERSONAL, DataClass.SENSITIVE, DataClass.FINANCIAL, DataClass.HEALTH})
AGENTS = frozenset({AgentId.MEMORY, AgentId.PERSONAL_ASSISTANT, AgentId.SUPERVISOR})
WORKING_SET_KIND = "memories"

_LABELS: dict[str, dict[MemoryCategory, str]] = {
    "en": {
        MemoryCategory.PROFILE: "profile",
        MemoryCategory.EPISODIC: "events",
        MemoryCategory.FINANCIAL: "financial",
        MemoryCategory.FITNESS: "fitness",
        MemoryCategory.VISUAL: "visual",
        MemoryCategory.KNOWLEDGE: "knowledge",
        MemoryCategory.CONVERSATION_STATE: "conversation",
    },
    "hi": {
        MemoryCategory.PROFILE: "प्रोफ़ाइल",
        MemoryCategory.EPISODIC: "घटनाओं",
        MemoryCategory.FINANCIAL: "वित्तीय",
        MemoryCategory.FITNESS: "फ़िटनेस",
        MemoryCategory.VISUAL: "तस्वीरों",
        MemoryCategory.KNOWLEDGE: "जानकारी",
        MemoryCategory.CONVERSATION_STATE: "बातचीत",
    },
    "hinglish": {
        MemoryCategory.PROFILE: "profile",
        MemoryCategory.EPISODIC: "events",
        MemoryCategory.FINANCIAL: "financial",
        MemoryCategory.FITNESS: "fitness",
        MemoryCategory.VISUAL: "visual",
        MemoryCategory.KNOWLEDGE: "knowledge",
        MemoryCategory.CONVERSATION_STATE: "conversation",
    },
}


def _pick(lang: str, en: str, hi: str, hinglish: str) -> str:
    return {"hi": hi, "hinglish": hinglish}.get(lang, en)


def _label(category: MemoryCategory | None, lang: str) -> str:
    table = _LABELS.get(lang, _LABELS["en"])
    return table[category] if category is not None else ""


# ---------------------------------------------------------------- models


class MemoryItem(BaseModel):
    id: str
    category: MemoryCategory
    text: str
    sensitivity: DataClass
    confidence: float
    source: str
    status: str = "active"
    last_verified_at: datetime | None = None
    score: float | None = None


def _item(record: MemoryRecord, score: float | None = None) -> MemoryItem:
    return MemoryItem(
        id=record.id,
        category=record.category,
        text=record.text,
        sensitivity=record.sensitivity,
        confidence=record.confidence,
        source=record.source,
        status=record.status,
        last_verified_at=record.last_verified_at,
        score=None if score is None else round(score, 4),
    )


def _memory_card(title: str, items: list[MemoryItem]) -> UICard:
    return UICard(
        kind="memory",
        title=title,
        payload={
            "items": [{k: v for k, v in i.model_dump(mode="json").items() if k != "score"} for i in items]
        },
    )


class RememberIn(BaseModel):
    text: str = Field(min_length=1, max_length=2000, description="What to remember, in the owner's words.")
    category: MemoryCategory | None = Field(default=None, description="Omit to choose automatically.")
    sensitivity: DataClass | None = Field(default=None, description="Omit to choose automatically.")


class RememberOut(BaseModel):
    outcome: Literal["created", "merged", "kept_existing", "skipped_disabled", "rejected_secret"]
    stored: bool
    item: MemoryItem | None = None
    category: MemoryCategory | None = None  # the category that was asked for or chosen


class SearchIn(BaseModel):
    query: str = Field(min_length=1, max_length=300)
    category: MemoryCategory | None = None
    limit: int = Field(default=5, ge=1, le=20)


class SearchOut(BaseModel):
    query: str
    count: int
    items: list[MemoryItem]


class ForgetIn(BaseModel):
    memory_id: str | None = Field(default=None, max_length=64, description="Exact id, from a search result.")
    query: str | None = Field(default=None, max_length=300, description="What to forget, in words.")

    @model_validator(mode="after")
    def _one_target(self) -> ForgetIn:
        if not (self.memory_id or (self.query and self.query.strip())):
            raise ValueError("give memory_id or query")
        return self


class ForgetOut(BaseModel):
    forgotten: bool
    reason: Literal["deleted", "not_found", "no_match", "ambiguous"]
    deleted: MemoryItem | None = None
    candidates: list[MemoryItem] = Field(default_factory=list)


# ---------------------------------------------------------------- summaries (built from result values only)


def remember_summary(r: RememberOut, lang: str) -> str:
    cat = _label(r.item.category if r.item else r.category, lang)
    match r.outcome:
        case "created":
            return _pick(
                lang,
                f"Saved to your {cat} memory.",
                f"आपकी {cat} स्मृति में सहेज लिया।",
                f"Maine aapki {cat} memory mein save kar liya.",
            )
        case "merged":
            return _pick(
                lang,
                f"I already had this in {cat}; updated it.",
                f"यह {cat} में पहले से था; मैंने इसे अपडेट कर दिया।",
                f"Ye {cat} mein pehle se tha; maine update kar diya.",
            )
        case "kept_existing":
            return _pick(
                lang,
                "You already have this saved, and I kept your edited version.",
                "यह पहले से सहेजा हुआ है, और मैंने आपका बदला हुआ संस्करण रखा।",
                "Ye pehle se saved hai, aur maine aapka edit kiya hua version rakha.",
            )
        case "skipped_disabled":
            return _pick(
                lang,
                f"Memory for {cat} is switched off, so I did not save it.",
                f"{cat} की स्मृति बंद है, इसलिए मैंने इसे नहीं सहेजा।",
                f"{cat} ki memory band hai, isliye maine save nahi kiya.",
            )
        case _:
            return _pick(
                lang,
                "I never store passwords, PINs or OTPs, so I did not save that.",
                "पासवर्ड, पिन या ओटीपी कभी नहीं सहेजे जाते, इसलिए इसे नहीं सहेजा।",
                "Password, PIN ya OTP kabhi save nahi kiye jaate, isliye ye save nahi kiya.",
            )


def search_summary(r: SearchOut, lang: str) -> str:
    if r.count == 0:
        return _pick(
            lang,
            "I don't remember anything about that.",
            "इस बारे में मुझे कुछ याद नहीं है।",
            "Is bare mein mujhe kuch yaad nahi hai.",
        )
    first = r.items[0].text.rstrip(" .")
    more = r.count - 1
    return _pick(
        lang,
        f"I remember: {first}." + (f" And {more} more." if more else ""),
        f"मुझे याद है: {first}।" + (f" और {more} बातें।" if more else ""),
        f"Mujhe yaad hai: {first}." + (f" Aur {more} baatein." if more else ""),
    )


def forget_summary(r: ForgetOut, lang: str) -> str:
    match r.reason:
        case "deleted":
            return _pick(
                lang, "Done, I forgot that.", "ठीक है, मैंने इसे भुला दिया।", "Theek hai, maine ise bhula diya."
            )
        case "ambiguous":
            return _pick(
                lang,
                f"I found {len(r.candidates)} similar memories. Which one should I forget?",
                f"मुझे {len(r.candidates)} मिलती-जुलती बातें मिलीं। कौन सी भुला दूँ?",
                f"Mujhe {len(r.candidates)} milti-julti baatein mili. Kaun si bhula doon?",
            )
        case _:
            return _pick(
                lang,
                "I could not find a memory like that.",
                "मुझे ऐसी कोई स्मृति नहीं मिली।",
                "Mujhe aisi koi memory nahi mili.",
            )


# ---------------------------------------------------------------- tools


def _remember_result(result: AddResult, category: MemoryCategory) -> RememberOut:
    return RememberOut(
        outcome=result.outcome,
        stored=result.stored,
        item=_item(result.record) if result.record else None,
        category=result.record.category if result.record else category,
    )


def build_tools(service: MemoryService) -> list[ToolSpec]:
    async def remember(ctx: ToolContext, args: RememberIn) -> RememberOut:
        guess = classify(args.text)
        category = args.category or guess.category
        sensitivity = max_sensitivity(args.sensitivity or DataClass.PERSONAL, guess.sensitivity)
        result = await service.add(
            category=category,
            text=args.text,
            sensitivity=sensitivity,
            source=source_for(ctx),
            confidence=1.0,
            status="active",
            gateway=ctx.gateway,
            mode=ctx.privacy_mode,
        )
        return _remember_result(result, category)

    async def search(ctx: ToolContext, args: SearchIn) -> SearchOut:
        recalled = await service.recall_hits(args.query, category=args.category, limit=args.limit, ctx=ctx)
        items = [_item(h.record, h.score) for h in recalled]
        # Idempotent display state (not a data change): lets "forget the second one" resolve.
        await ctx.set_working_set(
            WORKING_SET_KIND, [{"id": i.id, "text": i.text, "category": i.category.value} for i in items]
        )
        return SearchOut(query=args.query, count=len(items), items=items)

    async def forget(ctx: ToolContext, args: ForgetIn) -> ForgetOut:
        actor = ctx.device_id or ctx.agent.value
        if args.memory_id:
            try:
                record = await service.get(args.memory_id)
            except NotFound:
                return ForgetOut(forgotten=False, reason="not_found")
            deleted = await service.delete(args.memory_id, actor=actor)
            return ForgetOut(
                forgotten=deleted, reason="deleted" if deleted else "not_found", deleted=_item(record)
            )
        hits = await service.search(
            args.query or "",
            limit=5,
            statuses=("active", "pending_review"),
            only_enabled=False,  # the owner can always forget, even a category that is switched off
            allowed=ALL_BUT_SECRET,
            min_score=0.3,
            gateway=ctx.gateway,
            mode=ctx.privacy_mode,
        )
        if not hits:
            return ForgetOut(forgotten=False, reason="no_match")
        top, runner_up = hits[0].score, hits[1].score if len(hits) > 1 else 0.0
        if (len(hits) == 1 and top >= 0.45) or (top >= 0.6 and top - runner_up >= 0.15):
            record = hits[0].record
            await service.delete(record.id, actor=actor)
            return ForgetOut(forgotten=True, reason="deleted", deleted=_item(record))
        candidates = [_item(h.record, h.score) for h in hits]
        await ctx.set_working_set(
            WORKING_SET_KIND, [{"id": i.id, "text": i.text, "category": i.category.value} for i in candidates]
        )
        return ForgetOut(forgotten=False, reason="ambiguous", candidates=candidates)

    def remember_view(args: RememberIn) -> ApprovalView:
        details = [LabelValue(label="text", value=args.text)]
        if args.category:
            details.append(LabelValue(label="category", value=args.category.value))
        return ApprovalView(
            title="Save to memory", summary=f"Save to memory: {args.text}", details=tuple(details)
        )

    def forget_view(args: ForgetIn) -> ApprovalView:
        what = args.memory_id or args.query or ""
        return ApprovalView(
            title="Forget a memory",
            summary=f"Permanently forget: {what}",
            details=(LabelValue(label="memory_id" if args.memory_id else "query", value=what),),
        )

    return [
        ToolSpec(
            name="memory.remember",
            description="Save one fact to the owner's long-term memory when they ask ZORO to remember it.",
            input_model=RememberIn,
            output_model=RememberOut,
            handler=remember,
            risk=RiskLevel.MEDIUM,
            data_classes=MEMORY_CLASSES,
            permission="memory.write",
            agents=AGENTS,
            mcp_group="memory-mcp",
            rate_limit_per_min=30,
            summarizer=remember_summary,
            card=lambda r: _memory_card("Saved to memory", [r.item]) if r.item else None,
            approval_view=remember_view,
        ),
        ToolSpec(
            name="memory.search",
            description="Search what ZORO remembers about the owner (enabled categories, active records only).",
            input_model=SearchIn,
            output_model=SearchOut,
            handler=search,
            risk=RiskLevel.LOW,
            data_classes=MEMORY_CLASSES,
            permission="memory.read",
            agents=AGENTS,
            mcp_group="memory-mcp",
            summarizer=search_summary,
            card=lambda r: _memory_card("Memory", r.items) if r.items else None,
        ),
        ToolSpec(
            name="memory.forget",
            description="Permanently forget one memory, by id or by a description that matches one record.",
            input_model=ForgetIn,
            output_model=ForgetOut,
            handler=forget,
            risk=RiskLevel.MEDIUM,
            data_classes=MEMORY_CLASSES,
            permission="memory.write",
            agents=AGENTS,
            mcp_group="memory-mcp",
            rate_limit_per_min=30,
            summarizer=forget_summary,
            card=lambda r: _memory_card("Which memory?", r.candidates) if r.candidates else None,
            approval_view=forget_view,
        ),
    ]
