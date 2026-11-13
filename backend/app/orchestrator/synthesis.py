"""Synthesis: turn tool records into the reply.

When a model may see the data classes of the results, the voice agent phrases the reply in the
owner's language and preferred length from the tool results only. The numeric guard then checks
it: a reply with a number that no source contains is thrown away and the tools' own summarizer
sentences are used. With no permitted model the summarizer sentences are the reply.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from app.agents.access import model_permitted
from app.agents.calls import Budget, model_text_of
from app.agents.catalog import COMMON_RULES
from app.agents.runner import LANGUAGE_NAMES
from app.agents.spec import AgentCatalog
from app.core.types import AgentId, DataClass, PrivacyMode
from app.orchestrator import texts
from app.orchestrator.numeric_guard import invented_numbers
from app.providers.types import ChatMessage, ChatRequest, NoPermittedModel, ProviderError

log = logging.getLogger(__name__)

_LENGTHS = {
    "brief": "one or two short sentences",
    "balanced": "two to four sentences",
    "detailed": "a short paragraph that covers every result",
}


@dataclass
class Reply:
    text: str
    engine: str = "deterministic"  # "deterministic" | "model"
    data_classes: list[str] = field(default_factory=list)
    guard_rejected: bool = False  # a model text was discarded for an invented number
    model_calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0


def _sources(user_text: str, results: list[dict[str, Any]], recall: list[dict[str, Any]]) -> list[Any]:
    """Everything a number in the reply may legitimately come from: tool results, their summaries
    and cards, the owner's own words, and recalled memory."""
    sources: list[Any] = [user_text, [item.get("text", "") for item in recall]]
    for record in results:
        if record.get("status") == "completed":
            sources.extend([record.get("result"), record.get("summary") or "", record.get("card")])
    return sources


def spoken_records(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The records the reply is built from. A completed step that a later step of its chain
    continued from is intermediate (the later step speaks for the chain), and a follow-up that
    was skipped because the step before it did not complete says nothing of its own."""
    continued = {r.get("parent") for r in results if r.get("parent") and r.get("status") != "skipped"}
    return [
        r
        for r in results
        if r.get("status") != "skipped"
        and not (r.get("status") == "completed" and r.get("call_id") in continued)
    ]


def restricted(results: list[dict[str, Any]]) -> bool:
    """True when a result may not be shown to an external model (for example Strava data)."""
    return any(r.get("external_model_allowed") is False for r in results if r.get("status") == "completed")


def _join(parts: list[str]) -> str:
    seen: list[str] = []
    for part in parts:
        clean = part.strip()
        if clean and clean not in seen:
            seen.append(clean)
    return " ".join(seen)


async def synthesize(
    reg: Any,
    catalog: AgentCatalog,
    *,
    turn_id: str,
    lang: str,
    mode: PrivacyMode,
    user_text: str,
    results: list[dict[str, Any]],
    drafts: list[dict[str, Any]],
    recall: list[dict[str, Any]],
    length: str = "brief",
    stop: str | None = None,
    budget: Budget | None = None,
) -> Reply:
    sources = _sources(user_text, results, recall)
    # A result flagged "not for external models" keeps every model call of this reply local:
    # the request is made in strict private mode, where the gateway refuses external providers.
    prompt_mode = PrivacyMode.STRICT_PRIVATE if restricted(results) else mode
    results = spoken_records(results)
    reply = Reply(text="")
    classes: set[str] = set()
    for record in results:
        if record.get("status") == "completed":
            classes.update(record.get("data_classes") or [])

    # 1. Drafts written by model-path agents: kept only when every number has a source.
    accepted: dict[str, str] = {}
    for draft in drafts:
        text = str(draft.get("text") or "").strip()
        if not text:
            continue
        if invented_numbers(text, sources):
            reply.guard_rejected = True
            log.warning("numeric guard rejected an agent draft", extra={"agent": draft.get("agent")})
            continue
        accepted[str(draft["agent"])] = text
        classes.update(draft.get("data_classes") or [])

    # 2. Deterministic parts, agent by agent, in the order work was done.
    parts: list[str] = []
    agents_in_order: list[str] = []
    for item in [*drafts, *results]:
        agent = str(item.get("agent"))
        if agent not in agents_in_order:
            agents_in_order.append(agent)
    notes = {str(d["agent"]): d.get("note") for d in drafts}
    for agent in agents_in_order:
        own = [r for r in results if r.get("agent") == agent]
        if agent in accepted:
            parts.append(accepted[agent])
            own = [r for r in own if r.get("phase") == "action"]  # the draft covers the read-only work
        parts.extend(texts.sentence_for(record, lang) for record in own)
        if agent not in accepted and not own and agent in notes:
            trouble = texts.NOTHING_MATCHED if notes[agent] == "no_model" else texts.MODEL_TROUBLE
            parts.append(texts.say(lang, trouble))
    deterministic = _join(parts)

    # 3. Model phrasing of deterministic results, when permitted for their data classes.
    completed = [r for r in results if r.get("status") == "completed"]
    data_classes = frozenset(DataClass(c) for c in classes) | {DataClass.PERSONAL}
    spec = catalog.get(AgentId.VOICE)
    phrase = (
        bool(completed)
        and len(completed) == len(results)
        and not accepted
        and not reply.guard_rejected  # a rejected draft is replaced by summarizer sentences, not retried
        and stop is None
        and (budget is None or budget.exceeded() is None)
        and await model_permitted(reg, spec.task_class, data_classes, prompt_mode)
    )
    if phrase:
        blocks = "\n\n".join(f"[{r['tool']}]\n{model_text_of(r)}" for r in completed)
        request = ChatRequest(
            task=spec.task_class,
            messages=(
                ChatMessage(
                    role="system",
                    content=(
                        f"{spec.system_prompt}\n\n{COMMON_RULES}\n\n"
                        f"Reply in {LANGUAGE_NAMES.get(lang, 'English')}, in {_LENGTHS.get(length, _LENGTHS['brief'])}."
                    ),
                ),
                ChatMessage(role="user", content=f"I asked: {user_text}\n\nTool results:\n{blocks}"),
            ),
            max_output_tokens=spec.max_tokens,
            data_classes=data_classes,
            privacy_mode=prompt_mode,
            agent=AgentId.VOICE,
            turn_id=turn_id,
            timeout_s=spec.max_seconds,
        )
        try:
            resp = await reg.service("gateway").chat(request)
        except (NoPermittedModel, ProviderError) as exc:
            log.info("synthesis model unavailable", extra={"error_type": type(exc).__name__})
        else:
            reply.model_calls = 1
            reply.input_tokens = resp.usage.input_tokens
            reply.output_tokens = resp.usage.output_tokens
            if budget is not None:
                budget.tokens += resp.usage.input_tokens + resp.usage.output_tokens
            candidate = resp.text.strip()
            if candidate and not invented_numbers(candidate, sources):
                reply.text = candidate
                reply.engine = "model"
            elif candidate:
                reply.guard_rejected = True
                log.warning("numeric guard rejected the synthesized reply")

    if not reply.text:
        reply.text = deterministic
        reply.engine = "model" if accepted else "deterministic"
    if stop is not None:
        reply.text = _join([reply.text, texts.budget_message(stop, lang)])
    if not reply.text:
        reply.text = texts.say(lang, texts.NOTHING_MATCHED)
    reply.data_classes = sorted(classes) or [DataClass.PERSONAL.value]
    return reply
