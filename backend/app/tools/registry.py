"""Tool registry: the only place tools are looked up from."""

from __future__ import annotations

import re
from collections.abc import Iterator

from pydantic import BaseModel

from app.core.types import AgentId
from app.tools.spec import ToolSpec

_NAME = re.compile(r"^[a-z][a-z0-9_]*(\.[A-Za-z0-9_-]+)+$")
_GROUP = re.compile(r"^[a-z][a-z0-9-]*-mcp$")


class ToolRegistrationError(ValueError):
    pass


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, ToolSpec] = {}

    def register(self, spec: ToolSpec) -> ToolSpec:
        """Add a tool. Metadata is checked here once, so the executor can trust it."""
        if not _NAME.match(spec.name):
            raise ToolRegistrationError(f"tool name must look like 'package.verb_noun': {spec.name!r}")
        if spec.name in self._tools:
            raise ToolRegistrationError(f"tool already registered: {spec.name}")
        if not _GROUP.match(spec.mcp_group or ""):
            raise ToolRegistrationError(
                f"{spec.name}: mcp_group must name a tool group like 'finance-mcp', got {spec.mcp_group!r}"
            )
        if not (isinstance(spec.input_model, type) and issubclass(spec.input_model, BaseModel)):
            raise ToolRegistrationError(f"{spec.name}: input_model must be a Pydantic model class")
        if not (isinstance(spec.output_model, type) and issubclass(spec.output_model, BaseModel)):
            raise ToolRegistrationError(f"{spec.name}: output_model must be a Pydantic model class")
        if spec.executor == "backend":
            if spec.handler is None:
                raise ToolRegistrationError(f"{spec.name}: backend tools need a handler")
        elif spec.executor == "device":
            if spec.handler is not None:
                raise ToolRegistrationError(
                    f"{spec.name}: device tools run on the device and take no handler"
                )
            if not spec.device_platforms:
                raise ToolRegistrationError(f"{spec.name}: device tools must name their platforms")
        else:
            raise ToolRegistrationError(f"{spec.name}: executor must be 'backend' or 'device'")
        if spec.timeout_s <= 0 or spec.rate_limit_per_min <= 0:
            raise ToolRegistrationError(f"{spec.name}: timeout and rate limit must be positive")
        self._tools[spec.name] = spec
        return spec

    def get(self, name: str) -> ToolSpec | None:
        return self._tools.get(name)

    def __contains__(self, name: object) -> bool:
        return name in self._tools

    def __len__(self) -> int:
        return len(self._tools)

    def __iter__(self) -> Iterator[ToolSpec]:
        return iter(self.all())

    def all(self) -> list[ToolSpec]:
        return sorted(self._tools.values(), key=lambda spec: spec.name)

    def for_agent(self, agent: AgentId) -> list[ToolSpec]:
        """The agent's allowlist, derived from `ToolSpec.agents`."""
        return [spec for spec in self.all() if agent in spec.agents]

    def for_group(self, mcp_group: str) -> list[ToolSpec]:
        return [spec for spec in self.all() if spec.mcp_group == mcp_group]

    def groups(self) -> list[str]:
        return sorted({spec.mcp_group for spec in self._tools.values() if spec.mcp_group})
