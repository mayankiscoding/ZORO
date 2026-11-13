"""Explicit `expose` mappings in `config/mcp_servers.yaml` -> ZORO tools.

An external tool reaches an agent only through such a mapping, which names the agents, the risk
and the data classes. Their group is `external-mcp`, which the MCP gateway never serves (an
external server's tools are not passed back out), and their output is always untrusted.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field

from app.core.errors import Unavailable
from app.core.types import DataClass
from app.tools.spec import ToolContext, ToolSpec

from .clients import ExternalMcpError, McpClientRegistry
from .config import ExposedTool, ExternalServer, McpConfig

TOOL_PREFIX = "mcpx"
EXTERNAL_GROUP = "external-mcp"  # a real group for the registry; `McpGateway` refuses to serve it


class ExternalToolInput(BaseModel):
    arguments: dict[str, Any] = Field(default_factory=dict)


class ExternalToolOutput(BaseModel):
    server: str
    tool: str
    content: str  # untrusted, wrapped
    is_error: bool
    truncated: bool
    retrieved_at: datetime


def summarize(result: ExternalToolOutput, lang: str) -> str:
    if result.is_error:
        return {
            "hi": f"{result.server} ने एक त्रुटि लौटाई।",
            "hinglish": f"{result.server} ne error diya.",
        }.get(lang, f"{result.server} returned an error.")
    return {
        "hi": f"{result.server} से नतीजा मिल गया।",
        "hinglish": f"{result.server} se result mil gaya.",
    }.get(lang, f"Got a result from {result.server}.")


def _handler(clients: McpClientRegistry, server: ExternalServer, exposed: ExposedTool) -> Any:
    classes = frozenset(exposed.argument_data_classes)

    async def run(ctx: ToolContext, args: ExternalToolInput) -> ExternalToolOutput:
        try:
            result = await clients.call(ctx, server.name, exposed.tool, args.arguments, data_classes=classes)
        except ExternalMcpError as exc:
            raise Unavailable(f"{server.display_name}: {exc.code}") from exc
        return ExternalToolOutput(**result.model_dump(exclude={"untrusted"}))

    return run


def exposed_specs(config: McpConfig, clients: McpClientRegistry) -> list[ToolSpec]:
    specs: list[ToolSpec] = []
    for server in config.clients.servers:
        if not server.enabled:
            continue
        for exposed in server.expose:
            specs.append(
                ToolSpec(
                    name=f"{TOOL_PREFIX}.{server.name}.{exposed.name}",
                    description=exposed.description,
                    input_model=ExternalToolInput,
                    output_model=ExternalToolOutput,
                    handler=_handler(clients, server, exposed),
                    risk=exposed.risk,
                    data_classes=frozenset(exposed.result_data_classes) or frozenset({DataClass.PERSONAL}),
                    permission=exposed.permission,
                    agents=frozenset(exposed.agents),
                    mcp_group=EXTERNAL_GROUP,  # a real group, but never re-served through the gateway
                    timeout_s=server.timeout_s + 10,
                    untrusted_output=True,
                    summarizer=summarize,
                )
            )
    return specs
