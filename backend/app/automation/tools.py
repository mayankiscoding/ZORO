"""Automation tools. `list_routines` is LOW and read-only; `run_routine` and `save_routine` are MEDIUM
(the owner approves them, and every step inside a run is checked by the policy engine again as work that
the owner did not ask for in this turn)."""

from __future__ import annotations

import json
from typing import Any

from pydantic import BaseModel

from app.automation import summaries as s
from app.automation.runner import RoutineRunner
from app.automation.service import RoutineService
from app.automation.tools_io import ListIn, ListOut, RunToolIn, RunToolOut, SaveIn, SaveOut
from app.core.types import AgentId, DataClass, RiskLevel
from app.schemas.common import LabelValue
from app.tools.spec import ApprovalView, ToolContext, ToolSpec

READ, RUN, MANAGE = "automation.read", "automation.run", "automation.manage"
WORKING_SET = "routines"
READ_AGENTS = frozenset({AgentId.AUTOMATION, AgentId.PERSONAL_ASSISTANT, AgentId.VOICE})
WRITE_AGENTS = frozenset({AgentId.AUTOMATION, AgentId.PERSONAL_ASSISTANT})


def _short(value: Any, limit: int = 160) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    return text if len(text) <= limit else text[:limit] + "…"


def run_view(a: RunToolIn) -> ApprovalView:
    details = (
        LabelValue(label="routine", value=a.routine),
        *(LabelValue(label=f"param {k}", value=_short(v)) for k, v in a.params.items()),
    )
    return ApprovalView(
        title=f"Run routine {a.routine}",
        summary=f"Runs the saved steps of '{a.routine}'. Any step that changes something asks you again.",
        details=details,
    )


def save_view(a: SaveIn) -> ApprovalView:
    trig = a.trigger
    when = {
        "manual": "only when you ask",
        "daily": f"every day at {trig.time}",
        "weekly": f"on {', '.join(trig.days or [])} at {trig.time}",
        "interval": f"every {trig.every_minutes} minutes",
    }[trig.kind]
    steps = tuple(
        LabelValue(label=f"step {i + 1}", value=f"{st.tool} {_short(st.args)}")
        for i, st in enumerate(a.steps)
    )
    return ApprovalView(
        title=f"Save routine {a.name}",
        summary=f"{len(a.steps)} steps, runs {when}" + ("" if a.enabled else " (turned off)"),
        details=(LabelValue(label="name", value=a.name), LabelValue(label="runs", value=when), *steps),
    )


def build_tools(service: RoutineService, runner: RoutineRunner) -> list[ToolSpec]:
    async def list_routines(ctx: ToolContext, a: ListIn) -> ListOut:
        routines = await service.list_all(include_disabled=a.include_disabled)
        await ctx.set_working_set(WORKING_SET, [{"id": r.id, "name": r.name} for r in routines])
        return ListOut(routines=routines)

    async def run_routine(ctx: ToolContext, a: RunToolIn) -> RunToolOut:
        out = await runner.start(
            a.routine, params=a.params, trigger_kind="manual", device_id=ctx.device_id, lang=ctx.lang
        )
        return RunToolOut.model_validate(out.model_dump())

    async def save_routine(ctx: ToolContext, a: SaveIn) -> SaveOut:
        return SaveOut(routine=await service.save(a, created_by=ctx.device_id))

    def spec(
        name: str,
        description: str,
        inp: type[BaseModel],
        out: type[BaseModel],
        handler: Any,
        summarizer: Any,
        *,
        risk: RiskLevel,
        permission: str,
        agents: frozenset[AgentId],
        approval_view: Any = None,
        timeout_s: float = 20,
    ) -> ToolSpec:
        return ToolSpec(
            name=name,
            description=description,
            input_model=inp,
            output_model=out,
            handler=handler,
            risk=risk,
            data_classes=frozenset({DataClass.PERSONAL}),
            permission=permission,
            agents=agents,
            mcp_group="automation-mcp",
            summarizer=summarizer,
            approval_view=approval_view,
            timeout_s=timeout_s,
        )

    return [
        spec(
            "automation.list_routines",
            "List the owner's saved routines with their triggers and steps.",
            ListIn,
            ListOut,
            list_routines,
            s.list_summary,
            risk=RiskLevel.LOW,
            permission=READ,
            agents=READ_AGENTS,
        ),
        spec(
            "automation.run_routine",
            "Run a saved routine now. Steps that change something wait for the owner's approval.",
            RunToolIn,
            RunToolOut,
            run_routine,
            s.run_summary,
            risk=RiskLevel.MEDIUM,
            permission=RUN,
            agents=WRITE_AGENTS,
            approval_view=run_view,
            timeout_s=130,
        ),
        spec(
            "automation.save_routine",
            "Create or update a routine: ordered steps (tool name and argument template) and a manual or simple schedule trigger.",
            SaveIn,
            SaveOut,
            save_routine,
            s.save_summary,
            risk=RiskLevel.MEDIUM,
            permission=MANAGE,
            agents=WRITE_AGENTS,
            approval_view=save_view,
        ),
    ]
