from __future__ import annotations

import re
from decimal import Decimal
from typing import Any

import pytest

from app.core.money import format_inr
from app.core.types import AgentId, DataClass, PrivacyMode, RiskLevel, TaskClass
from app.finance.suggest import suggest_categories
from app.plugins import PluginRegistry
from app.providers.types import NoPermittedModel
from app.tools.outcome import Completed, Denied, Failed, NeedsApproval
from tests.fakes.gateway import FakeGateway
from tests.finance.conftest import make_ctx
from tests.finance.data import history_csv

D = Decimal
READ_TOOLS = {
    "finance.spending_summary": {"period": "this_month"},
    "finance.transactions_search": {"period": "last_30_days", "merchant": "Swiggy"},
    "finance.category_breakdown": {"period": "2026-11"},
    "finance.income_expense": {"period": "this_year"},
    "finance.merchant_report": {"period": "this_year", "merchant": "netflix"},
    "finance.recurring": {},
    "finance.budget_status": {},
    "finance.cashflow_forecast": {"horizon_days": 30},
}
_MONEY = re.compile(r"-?₹[\d,]+\.\d{2}")


@pytest.fixture
async def seeded(registry: PluginRegistry) -> PluginRegistry:
    await registry.service("finance_imports").import_file("history.csv", history_csv())
    await registry.service("finance_insights").set_budget("food", D("1000.00"))
    return registry


async def _run(
    registry: PluginRegistry, tool: str, args: dict[str, Any], *, call_id: str = "c1", **ctx: Any
) -> Any:
    return await registry.service("tool_executor").execute(
        make_ctx(registry, **ctx), tool, args, call_id=call_id
    )


def _money_in(value: Any) -> set[str]:
    """Every Decimal in a result, formatted as the summarizer formats money."""
    found: set[str] = set()
    if isinstance(value, Decimal):
        found.add(format_inr(value))
    elif isinstance(value, dict):
        for inner in value.values():
            found |= _money_in(inner)
    elif isinstance(value, list):
        for inner in value:
            found |= _money_in(inner)
    return found


def test_tool_metadata_is_static_and_complete(registry: PluginRegistry) -> None:
    names = [t.name for t in registry.tools if t.name.startswith("finance.")]
    assert len(names) == 10
    for spec in registry.tools:
        assert spec.data_classes == frozenset({DataClass.FINANCIAL}) and spec.mcp_group == "finance-mcp"
        assert spec.summarizer is not None
        write = spec.name in {"finance.set_budget", "finance.recategorize"}
        assert spec.risk == (RiskLevel.MEDIUM if write else RiskLevel.LOW)
        assert spec.permission == ("finance.write" if write else "finance.read")
        assert (spec.approval_view is not None) == write


@pytest.mark.parametrize("lang", ["en", "hi", "hinglish"])
async def test_summaries_state_exact_figures_from_the_result(seeded: PluginRegistry, lang: str) -> None:
    for i, (tool, args) in enumerate(READ_TOOLS.items()):
        outcome = await _run(seeded, tool, args, call_id=f"{lang}{i}", lang=lang)
        assert isinstance(outcome, Completed), (tool, outcome)
        assert outcome.summary, tool
        figures = set(_MONEY.findall(outcome.summary))
        assert figures, (tool, outcome.summary)
        assert figures <= _money_in(outcome.result.model_dump()), (tool, outcome.summary)
        if lang == "hi":
            assert re.search(r"[ऀ-ॿ]", outcome.summary), outcome.summary
        else:
            assert not re.search(r"[ऀ-ॿ]", outcome.summary), outcome.summary


async def test_summary_states_the_period(seeded: PluginRegistry) -> None:
    out = await _run(seeded, "finance.spending_summary", {"period": "2026-10"}, lang="hi")
    assert isinstance(out, Completed)
    assert "अक्टूबर 2026" in (out.summary or "") and format_inr(out.result.spent) in (out.summary or "")
    en = await _run(
        seeded, "finance.spending_summary", {"period": "2026-10", "category": "bills"}, call_id="c2"
    )
    assert (
        isinstance(en, Completed)
        and en.summary == "You spent ₹1,490.00 on bills and utilities in October 2026."
    )
    assert en.card is not None and en.card.kind == "finance_summary"


async def test_transactions_card_and_working_set(seeded: PluginRegistry) -> None:
    out = await _run(seeded, "finance.transactions_search", {"period": "this_month", "merchant": "Uber"})
    assert isinstance(out, Completed) and out.card is not None and out.card.kind == "transactions"
    ctx = make_ctx(seeded)
    shown = await ctx.working_set("transactions")
    assert [s["id"] for s in shown] == [t.id for t in out.result.items]


async def test_recategorize_by_position_is_medium_risk(seeded: PluginRegistry) -> None:
    await _run(seeded, "finance.transactions_search", {"period": "this_month", "merchant": "Uber"})
    args = {"position": 2, "category": "shopping"}
    asked = await _run(seeded, "finance.recategorize", args, call_id="r1", user_initiated=False)
    assert isinstance(asked, NeedsApproval)
    assert "shopping" in asked.request.summary
    done = await _run(seeded, "finance.recategorize", args, call_id="r2")
    assert isinstance(done, Completed)
    assert done.result.transaction.category == "shopping" and done.result.changed == 1
    assert "₹250.00" in (done.summary or "")
    missing = await _run(seeded, "finance.recategorize", {"position": 9, "category": "food"}, call_id="r3")
    assert isinstance(missing, Failed)


async def test_set_budget_tool_and_float_rejected(seeded: PluginRegistry) -> None:
    ok = await _run(seeded, "finance.set_budget", {"category": "food", "limit": "8000"}, call_id="b1")
    assert isinstance(ok, Completed) and ok.result.limit == D("8000.00")
    assert ok.summary == "Set your monthly food and dining budget to ₹8,000.00."
    bad = await _run(seeded, "finance.set_budget", {"category": "food", "limit": 8000.5}, call_id="b2")
    assert isinstance(bad, Failed) and bad.error == "invalid_arguments"
    period = await _run(seeded, "finance.spending_summary", {"period": "next decade"}, call_id="b3")
    assert isinstance(period, Failed) and period.error == "invalid_arguments"


async def test_permission_and_allowlist(seeded: PluginRegistry) -> None:
    await seeded.service("permissions").set("finance.read", False)
    denied = await _run(seeded, "finance.spending_summary", {}, call_id="p1")
    assert isinstance(denied, Denied) and denied.reason == "permission_not_granted:finance.read"
    await seeded.service("permissions").set("finance.read", True)
    other = await _run(seeded, "finance.spending_summary", {}, call_id="p2", agent=AgentId.MUSIC)
    assert isinstance(other, Denied) and other.reason == "agent_not_allowed"


async def test_model_suggestion_sends_names_only_and_respects_policy(seeded: PluginRegistry) -> None:
    sf, cats = seeded.service("session_factory"), seeded.service("finance_categories")
    blocked = FakeGateway([NoPermittedModel(TaskClass.INTENT_CLASSIFICATION)])
    refused = await suggest_categories(sf, cats, blocked, PrivacyMode.STRICT_PRIVATE)
    assert refused.status == "unavailable" and refused.reason == "NoPermittedModel"
    assert blocked.requests[0].privacy_mode is PrivacyMode.STRICT_PRIVATE
    gateway = FakeGateway([{"suggestions": [{"merchant": "Kumar Stores", "category": "groceries"},
                                            {"merchant": "Kumar Stores", "category": "not_a_category"}]}])  # fmt: skip
    result = await suggest_categories(sf, cats, gateway, PrivacyMode.CLOUD_INTELLIGENCE)
    assert result.status == "applied" and result.applied == {"Kumar Stores": "groceries"}
    request = gateway.requests[0]
    assert (
        request.data_classes == frozenset({DataClass.FINANCIAL})
        and request.task is TaskClass.INTENT_CLASSIFICATION
    )
    sent = request.messages[1].content
    assert "Kumar Stores" in sent and not re.search(r"\d", sent)  # no amounts, dates or references
    again = await suggest_categories(sf, cats, FakeGateway(), PrivacyMode.CLOUD_INTELLIGENCE)
    assert again.status == "nothing_to_do"
    none = await suggest_categories(sf, cats, None, PrivacyMode.STRICT_PRIVATE)
    assert none.status == "unavailable"
