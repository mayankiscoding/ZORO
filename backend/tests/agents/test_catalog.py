"""The seventeen agent specs, the derived tool allowlists and the plugin."""

from __future__ import annotations

import re
from pathlib import Path

import yaml

import app.agents as agents_pkg
from app.agents.catalog import COMMON_RULES, default_specs
from app.agents.plugin import register
from app.agents.spec import AgentCatalog, AgentReply, AgentTask, RoutingDecision
from app.core.settings import Settings
from app.core.types import AgentId, CapabilityStatus, TaskClass
from app.plugins import PluginRegistry
from tests.fakes.gateway import FakeGateway
from tests.orchestrator.toolkit import Toolbox


def test_there_are_seventeen_specific_specs() -> None:
    specs = default_specs()
    assert len(specs) == 17 and {spec.id for spec in specs} == set(AgentId)
    prompts = [spec.system_prompt for spec in specs]
    assert len(set(prompts)) == 17 and all(len(prompt) > 300 for prompt in prompts)
    for spec in specs:
        assert spec.role and isinstance(spec.task_class, TaskClass)
        assert spec.max_seconds > 0 and spec.max_tokens > 0 and spec.max_tool_iterations >= 0
        assert spec.retry.max_attempts >= 1 and spec.fallback.on_no_model in ("deterministic", "decline")
        assert issubclass(spec.input_model, AgentTask) and spec.output_model in (AgentReply, RoutingDecision)
    by_id = {spec.id: spec for spec in specs}
    assert by_id[AgentId.SUPERVISOR].output_model is RoutingDecision
    assert (
        by_id[AgentId.SUPERVISOR].max_tool_iterations == 0 and by_id[AgentId.VOICE].max_tool_iterations == 0
    )
    assert "diagnosis" in by_id[AgentId.FITNESS].system_prompt
    assert "never place" in by_id[AgentId.INVESTMENT].system_prompt
    assert "never make or change" in by_id[AgentId.SECURITY].system_prompt
    assert by_id[AgentId.FINANCE].task_class is TaskClass.FINANCIAL_INTERPRETATION
    assert "untrusted" in COMMON_RULES and "Never invent a number" in COMMON_RULES


def test_no_model_or_provider_names_in_agent_code(settings: Settings) -> None:
    config = yaml.safe_load((settings.config_dir / "models.yaml").read_text(encoding="utf-8"))
    names = {str(m["id"]).lower() for m in config["models"]}
    names |= {str(m.get("model_name", m["id"])).lower() for m in config["models"]}
    names |= {
        "gemini",
        "gpt-",
        "openai",
        "deepseek",
        "ollama",
        "llama",
        "qwen",
        "grok",
        "kimi",
        "claude",
        "groq",
    }
    sources = sorted(Path(agents_pkg.__file__).parent.glob("*.py"))
    sources += sorted((Path(agents_pkg.__file__).parent.parent / "orchestrator").glob("*.py"))
    assert len(sources) > 15
    for path in sources:
        text = path.read_text(encoding="utf-8").lower()
        found = sorted(name for name in names if re.search(rf"(?<![a-z0-9_]){re.escape(name)}", text))
        assert not found, f"{path.name} names a model or provider: {found}"


def test_tools_are_derived_from_the_registry(registry: PluginRegistry, box: Toolbox) -> None:
    catalog: AgentCatalog = registry.service("agents")
    assert len(catalog) == 17 and [spec.id for spec in catalog.all()] == list(AgentId)
    assert [tool.name for tool in catalog.tools(AgentId.SHOPPING)] == [
        "test.add_to_basket",
        "test.search_products",
    ]
    assert [tool.name for tool in catalog.tools(AgentId.SECURITY)] == [
        "security.explain_approval",
        "security.explain_privacy_mode",
    ]
    assert catalog.tools(AgentId.SUPERVISOR) == [] and catalog.tools(AgentId.VOICE) == []
    for agent in AgentId:
        assert all(agent in tool.agents for tool in catalog.tools(agent))
        assert {t.name for t in catalog.tools(agent)} == {
            t.name for t in registry.tools.all() if agent in t.agents
        }


def test_plugin_registers_services_and_honest_capabilities(registry: PluginRegistry) -> None:
    assert registry.has_service("agents") and registry.has_service("agent_runner")
    register(registry)  # the orchestrator may call it again: no duplicate registration
    assert registry.intents.get("security.explain_privacy_mode") is not None
    reasoning = registry.capabilities.get("agents.model_reasoning")
    assert reasoning is not None and reasoning.status is CapabilityStatus.UNAVAILABLE  # no gateway loaded
    registry.provide("gateway", FakeGateway())
    reasoning = registry.capabilities.get("agents.model_reasoning")
    assert reasoning is not None and reasoning.status is CapabilityStatus.WORKING_LOCAL
    local = registry.capabilities.get("agents.deterministic")
    assert local is not None and local.status is CapabilityStatus.WORKING_LOCAL
