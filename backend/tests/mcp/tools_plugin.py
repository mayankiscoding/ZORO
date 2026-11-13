"""Test-only plugin: small tools in two MCP groups, registered like any package's tools."""

from __future__ import annotations

import asyncio
from typing import Any

from pydantic import BaseModel, Field

from app.core.types import AgentId, DataClass, DevicePlatform, RiskLevel
from app.tools.spec import ToolContext, ToolSpec


class EchoIn(BaseModel):
    text: str = Field(max_length=200)
    count: int = Field(default=1, ge=1, le=5)


class EchoOut(BaseModel):
    echoed: str


class SendIn(BaseModel):
    to: str
    body: str


class SendOut(BaseModel):
    sent_to: str
    body: str


class AlarmIn(BaseModel):
    time: str


class AlarmOut(BaseModel):
    alarm_id: str


SENT: list[SendIn] = []  # what the MEDIUM tool actually did


async def echo(ctx: ToolContext, args: EchoIn) -> EchoOut:
    return EchoOut(echoed=args.text * args.count)


async def send(ctx: ToolContext, args: SendIn) -> SendOut:
    SENT.append(args)
    return SendOut(sent_to=args.to, body=args.body)


async def slow(ctx: ToolContext, args: EchoIn) -> EchoOut:
    await asyncio.sleep(5)
    return EchoOut(echoed=args.text)


async def bad(ctx: ToolContext, args: EchoIn) -> dict[str, Any]:
    return {"unexpected": args.text}


async def big(ctx: ToolContext, args: EchoIn) -> EchoOut:
    return EchoOut(echoed="x" * 300_000)


def summary(result: Any, lang: str) -> str:
    return {"hi": "हो गया।", "hinglish": "Ho gaya."}.get(lang, "Done.")


def tool(name: str, handler: Any, **overrides: Any) -> ToolSpec:
    fields: dict[str, Any] = {
        "name": name,
        "description": f"Test tool {name}.",
        "input_model": EchoIn,
        "output_model": EchoOut,
        "handler": handler,
        "risk": RiskLevel.LOW,
        "data_classes": frozenset({DataClass.PERSONAL}),
        "permission": None,
        "agents": frozenset({AgentId.PERSONAL_ASSISTANT}),
        "mcp_group": "test-mcp",
        "summarizer": summary,
    }
    fields.update(overrides)
    return ToolSpec(**fields)


def register(reg: Any) -> None:
    reg.add_tool(tool("test.echo", echo))
    reg.add_tool(
        tool(
            "test.send",
            send,
            input_model=SendIn,
            output_model=SendOut,
            risk=RiskLevel.MEDIUM,
            agents=frozenset({AgentId.COMMUNICATION}),
        )
    )
    reg.add_tool(tool("test.slow", slow, timeout_s=0.2))
    reg.add_tool(tool("test.bad", bad))
    reg.add_tool(tool("test.big", big))
    reg.add_tool(tool("test.limited", echo, rate_limit_per_min=2))
    reg.add_tool(tool("test.web", echo, untrusted_output=True))
    reg.add_tool(tool("test.wire", echo, risk=RiskLevel.CRITICAL))
    reg.add_tool(
        tool(
            "test.alarm",
            None,
            input_model=AlarmIn,
            output_model=AlarmOut,
            executor="device",
            device_platforms=frozenset({DevicePlatform.MACOS}),
        )
    )
    reg.add_tool(tool("other.echo", echo, mcp_group="other-mcp"))
