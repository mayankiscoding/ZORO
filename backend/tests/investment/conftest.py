"""Investment tests: only the investment plugin and a fixed clock (13 Nov 2026, noon in India)."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any

import pytest

from app.core.clock import FixedClock
from app.core.types import AgentId
from app.investment.config import InvestmentConfig, InvestmentConfigSource, config_path
from app.investment.services import InvestmentServices
from app.plugins import PluginRegistry
from app.tools.spec import ToolContext

NOW = datetime(2026, 11, 13, 6, 30, tzinfo=UTC)


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.investment.plugin",)


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(NOW)


@pytest.fixture
def cfg() -> InvestmentConfig:
    """The real config/india_charges.yaml (tests check the shipped values)."""
    return InvestmentConfigSource(config_path(None)).current()


@pytest.fixture
def svc(registry: PluginRegistry) -> InvestmentServices:
    service: InvestmentServices = registry.service("investment")
    return service


def make_ctx(registry: PluginRegistry, **overrides: Any) -> ToolContext:
    fields: dict[str, Any] = {
        "turn_id": "turn_inv",
        "agent": AgentId.INVESTMENT,
        "conversation_id": "conv_inv",
        "user_initiated": True,
    }
    fields.update(overrides)
    return registry.tool_context(**fields)
