"""The security agent explains policy decisions and never changes them."""

from __future__ import annotations

import re
from dataclasses import replace
from typing import Any

import pytest

from app.agents.security import _REASONS, explain_reason
from app.core.types import AgentId, ApprovalLevel, DataClass, PrivacyMode, RiskLevel
from app.plugins import PluginRegistry
from app.tools.outcome import Completed
from app.tools.spec import ToolContext
from tests.orchestrator.toolkit import Toolbox

DEVANAGARI = re.compile(r"[ऀ-ॿ]")


def ctx(registry: PluginRegistry, **kw: Any) -> ToolContext:
    return registry.tool_context(turn_id="turn_sec", agent=AgentId.SECURITY, **kw)


async def run(
    registry: PluginRegistry, tool: str, args: dict[str, object], n: int, **kw: object
) -> Completed:
    outcome = await registry.service("tool_executor").execute(
        ctx(registry, **kw), tool, args, call_id=f"sec{n}"
    )
    assert isinstance(outcome, Completed)
    return outcome


@pytest.mark.parametrize("code", sorted(_REASONS))
def test_every_reason_is_explained_in_three_languages(code: str) -> None:
    en, hi, hinglish = (explain_reason(code, lang) for lang in ("en", "hi", "hinglish"))
    assert en and hinglish and len({en, hi, hinglish}) == 3
    assert DEVANAGARI.search(hi) and not DEVANAGARI.search(en) and not DEVANAGARI.search(hinglish)


def test_unknown_and_parameterised_reasons() -> None:
    assert explain_reason("permission_not_granted:finance.read", "en").startswith("You have not granted")
    assert explain_reason("something_new", "en") == "The security policy did not allow that."
    assert explain_reason("kill_switch", "fr") == explain_reason("kill_switch", "en")


async def test_explains_why_an_action_needs_approval(registry: PluginRegistry, box: Toolbox) -> None:
    high = await run(registry, "security.explain_approval", {"tool": "test.send_message"}, 1)
    assert high.result.model_dump(mode="json") == {
        "tool": "test.send_message", "risk": "high", "decision": "approval", "level": "confirm", "reason": "high_risk",
    }  # fmt: skip
    assert "always needs your confirmation" in (high.summary or "")

    tainted = await run(registry, "security.explain_approval", {"tool": "test.send_message"}, 2, tainted=True)
    assert tainted.result.level is ApprovalLevel.BIOMETRIC and tainted.result.reason == "high_tainted"  # type: ignore[attr-defined]

    low = await run(registry, "security.explain_approval", {"tool": "test.find_tracks"}, 3, lang="hi")
    assert low.result.decision == "allow" and low.result.risk is RiskLevel.LOW  # type: ignore[attr-defined]
    assert DEVANAGARI.search(low.summary or "")

    general = await run(registry, "security.explain_approval", {}, 4, lang="hinglish")
    assert general.result.decision == "general" and "Face ID ya Touch ID" in (general.summary or "")  # type: ignore[attr-defined]
    unknown = await run(registry, "security.explain_approval", {"tool": "x.y"}, 5)
    assert unknown.result.reason == "unknown_tool"  # type: ignore[attr-defined]

    registry.add_permission("test.gated", "Test permission", False)
    tracks = registry.tools.get("test.find_tracks")
    assert tracks is not None
    gated = replace(tracks, name="test.gated_tracks", permission="test.gated")
    registry.add_tool(gated)
    denied = await run(registry, "security.explain_approval", {"tool": "test.gated_tracks"}, 6)
    assert denied.result.decision == "deny" and denied.result.reason == "permission_not_granted:test.gated"  # type: ignore[attr-defined]
    assert "Security and privacy" in (denied.summary or "")


async def test_explains_the_privacy_mode_without_changing_anything(
    registry: PluginRegistry, box: Toolbox
) -> None:
    privacy = registry.service("privacy_state")
    strict = await run(registry, "security.explain_privacy_mode", {}, 1)
    assert strict.result.model_dump(mode="json") == {
        "mode": "strict_private",
        "kill_switch": False,
        "external_classes": [],
    }
    assert "nothing is sent to cloud models" in (strict.summary or "")
    assert strict.data_classes == frozenset({DataClass.PERSONAL})

    await privacy.set_mode(PrivacyMode.CLOUD_INTELLIGENCE)
    await registry.service("permissions").set("cloud.financial", True)
    cloud = await run(registry, "security.explain_privacy_mode", {}, 2, lang="hinglish")
    assert cloud.result.external_classes == [DataClass.PUBLIC, DataClass.PERSONAL, DataClass.FINANCIAL]  # type: ignore[attr-defined]
    assert "public, personal, financial" in (cloud.summary or "") and "Cloud intelligence on hai" in (
        cloud.summary or ""
    )

    # Explaining is read-only: the mode, the grants and the approval queue are untouched.
    assert await privacy.stored_mode() is PrivacyMode.CLOUD_INTELLIGENCE
    assert await registry.service("permissions").is_granted("cloud.sensitive") is False
    assert await registry.service("approvals").list_pending() == []
    for spec in registry.service("agents").tools(AgentId.SECURITY):
        assert spec.risk is RiskLevel.LOW and spec.executor == "backend" and spec.permission is None

    # Only the security agent may use these tools.
    other = registry.tool_context(turn_id="turn_sec", agent=AgentId.FINANCE)
    refused = await registry.service("tool_executor").execute(
        other, "security.explain_privacy_mode", {}, call_id="sec9"
    )
    assert getattr(refused, "reason", "") == "agent_not_allowed"
