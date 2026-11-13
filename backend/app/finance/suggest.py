"""Optional model suggestion of categories for merchants no rule recognises.

Only merchant names are sent (never amounts, dates, references or account details), marked as
FINANCIAL data so the gateway's egress policy decides whether any model may see them. In strict
private mode only local models qualify; when none is permitted nothing changes. Suggestions are
stored with source "model" and confidence 50 and never override a rule or an owner choice.
"""

from __future__ import annotations

import json
from typing import Any, Literal

from pydantic import BaseModel
from sqlalchemy import select, update

from app.core.types import AgentId, DataClass, PrivacyMode, TaskClass
from app.db.session import SessionFactory
from app.finance.analytics import counted
from app.finance.categories import CategoryConfigSource
from app.finance.models import FinanceTransaction as T
from app.providers.types import ChatMessage, ChatRequest, NoPermittedModel, ProviderError

MAX_MERCHANTS = 30
MODEL_CONFIDENCE = 50


class SuggestResult(BaseModel):
    status: Literal["applied", "nothing_to_do", "unavailable"]
    reason: str = ""
    asked: int = 0
    applied: dict[str, str] = {}  # merchant name -> category


_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "suggestions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"merchant": {"type": "string"}, "category": {"type": "string"}},
                "required": ["merchant", "category"],
            },
        }
    },
    "required": ["suggestions"],
}


async def suggest_categories(
    session_factory: SessionFactory, categories: CategoryConfigSource, gateway: Any, privacy_mode: PrivacyMode
) -> SuggestResult:
    if gateway is None:
        return SuggestResult(status="unavailable", reason="no_model_gateway")
    config = categories.current()
    async with session_factory() as session:
        rows = (
            await session.execute(
                select(T.merchant_key, T.counterparty)
                .where(counted(), T.category_source == "default", T.direction == "debit")
                .group_by(T.merchant_key, T.counterparty)
                .order_by(T.merchant_key)
            )
        ).all()
    names: dict[str, str] = {}
    for key, name in rows:
        if not str(key).startswith(("unknown", "upi payee")):
            names.setdefault(str(name), str(key))
    if not names:
        return SuggestResult(status="nothing_to_do")
    asked = sorted(names)[:MAX_MERCHANTS]
    allowed = [c.id for c in config.categories if c.direction != "credit"]
    request = ChatRequest(
        task=TaskClass.INTENT_CLASSIFICATION,
        messages=(
            ChatMessage(role="system", content=(
                "Assign each Indian merchant name to one category id from this list: "
                + ", ".join(allowed) + ". Answer JSON only. Use 'uncategorised' when unsure."
            )),
            ChatMessage(role="user", content=json.dumps({"merchants": asked}, ensure_ascii=False)),
        ),
        response_schema=_SCHEMA, max_output_tokens=800, temperature=0,
        data_classes=frozenset({DataClass.FINANCIAL}), privacy_mode=privacy_mode, agent=AgentId.FINANCE,
    )  # fmt: skip
    try:
        response = await gateway.chat(request)
    except NoPermittedModel as exc:
        return SuggestResult(status="unavailable", reason=type(exc).__name__, asked=len(asked))
    except ProviderError as exc:
        return SuggestResult(status="unavailable", reason=exc.kind, asked=len(asked))
    parsed = response.parsed if isinstance(response.parsed, dict) else {}
    applied: dict[str, str] = {}
    async with session_factory() as session:
        for item in parsed.get("suggestions") or []:
            if not isinstance(item, dict):
                continue
            name, category = str(item.get("merchant", "")), str(item.get("category", ""))
            if name not in asked or category not in allowed or category == config.default_debit:
                continue
            await session.execute(
                update(T)
                .where(T.merchant_key == names[name], T.category_source == "default", T.direction == "debit")
                .values(category=category, category_source="model", confidence=MODEL_CONFIDENCE)
            )
            applied[name] = category
        await session.commit()
    return SuggestResult(status="applied", asked=len(asked), applied=applied)
