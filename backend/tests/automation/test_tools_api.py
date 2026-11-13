"""Automation tools (approval views, summaries), intents in three languages, and the routes."""

from __future__ import annotations

import re
from typing import Any

import httpx
import pytest

from app.automation.intents import build_intents
from app.core.types import AgentId, ApprovalLevel, DataClass, RiskLevel
from app.plugins import PluginRegistry
from app.tools.intents import IntentContext
from app.tools.outcome import Completed, Denied, Failed, NeedsApproval
from tests.automation.conftest import NOW, Recorder
from tests.conftest import PairedDevice

_NUM = re.compile(r"\d+")
STEPS = [
    {"tool": "test.echo", "args": {"text": "hello"}},
    {"tool": "test.write", "args": {"note": "buy milk"}},
]


def ctx(registry: PluginRegistry, **kw: Any) -> Any:
    fields: dict[str, Any] = {
        "turn_id": "t_auto",
        "agent": AgentId.AUTOMATION,
        "conversation_id": "conv_auto",
        "user_initiated": True,
    }
    fields.update(kw)
    return registry.tool_context(**fields)


async def call(registry: PluginRegistry, tool: str, args: dict[str, Any], cid: str, **kw: Any) -> Any:
    return await registry.service("tool_executor").execute(ctx(registry, **kw), tool, args, call_id=cid)


def test_metadata(registry: PluginRegistry) -> None:
    specs = {t.name: t for t in registry.tools if t.name.startswith("automation.")}
    assert {n: s.risk for n, s in specs.items()} == {
        "automation.list_routines": RiskLevel.LOW,
        "automation.run_routine": RiskLevel.MEDIUM,
        "automation.save_routine": RiskLevel.MEDIUM,
    }
    for spec in specs.values():
        assert (
            spec.data_classes == frozenset({DataClass.PERSONAL})
            and spec.executor == "backend"
            and spec.mcp_group == "automation-mcp"
        )
        assert spec.summarizer and AgentId.AUTOMATION in spec.agents
    assert (
        specs["automation.list_routines"].permission == "automation.read"
        and specs["automation.run_routine"].permission == "automation.run"
    )
    assert specs["automation.save_routine"].approval_view and specs["automation.run_routine"].approval_view
    assert AgentId.SHOPPING not in specs["automation.run_routine"].agents
    assert specs["automation.run_routine"].timeout_s > 120  # longer than a run's own time limit


async def test_save_needs_the_owner_unless_the_owner_asked_in_this_turn(
    registry: PluginRegistry, paired_device: PairedDevice
) -> None:
    args = {"name": "Morning", "steps": STEPS, "trigger": {"kind": "daily", "time": "07:30"}}
    pending = await call(
        registry,
        "automation.save_routine",
        args,
        "s1",
        user_initiated=False,
        device_id=paired_device.device_id,
    )
    assert isinstance(pending, NeedsApproval) and pending.request.level is ApprovalLevel.CONFIRM
    view = pending.request
    assert (
        view.title == "Save routine Morning"
        and "2 steps" in view.summary
        and "every day at 07:30" in view.summary
    )
    labels = {d.label: d.value for d in view.details}
    assert (
        labels["step 1"].startswith("test.echo")
        and "buy milk" in labels["step 2"]
        and labels["runs"] == "every day at 07:30"
    )
    assert (
        await registry.service("automation_routines").list_all() == []
    )  # nothing saved before the owner approves
    done = await registry.service("tool_executor").resume_with_approval(
        ctx(registry, user_initiated=False, device_id=paired_device.device_id),
        "s1",
        paired_device.signer.sign_approval(view),
    )
    assert (
        isinstance(done, Completed)
        and done.result.routine.created
        and done.result.routine.next_run_at is not None
    )  # type: ignore[attr-defined]

    direct = await call(registry, "automation.save_routine", {**args, "name": "Evening"}, "s2")
    assert isinstance(direct, Completed)  # the owner asked for it in this turn
    updated = await call(
        registry, "automation.save_routine", {**args, "name": "evening", "description": "new"}, "s3"
    )
    assert (
        isinstance(updated, Completed)
        and not updated.result.routine.created
        and len(await registry.service("automation_routines").list_all()) == 2
    )


async def test_save_refuses_bad_routines_before_any_approval(registry: PluginRegistry) -> None:
    recursive = await call(
        registry,
        "automation.save_routine",
        {"name": "X", "steps": [{"tool": "automation.run_routine", "args": {"routine": "X"}}]},
        "b1",
        user_initiated=False,
    )
    assert (
        isinstance(recursive, Failed) and recursive.error == "invalid_arguments"
    )  # no approval was even requested
    assert await registry.service("approvals").list_pending() == []
    placeholder = await call(
        registry,
        "automation.save_routine",
        {"name": "X", "steps": [{"tool": "test.echo", "args": {"text": "{{steps.3.x}}"}}]},
        "b2",
        user_initiated=False,
    )
    assert isinstance(placeholder, Failed) and placeholder.error == "invalid_arguments"
    unknown = await call(
        registry,
        "automation.save_routine",
        {"name": "X", "steps": [{"tool": "test.nothing", "args": {}}]},
        "b3",
    )
    assert (
        isinstance(unknown, Failed) and unknown.error == "routine_invalid"
    )  # needs the registry: checked in the handler
    wrong_agent = await call(
        registry, "automation.save_routine", {"name": "X", "steps": STEPS}, "b4", agent=AgentId.SHOPPING
    )
    assert isinstance(wrong_agent, Denied) and wrong_agent.reason == "agent_not_allowed"
    await registry.service("permissions").set("automation.manage", False)
    no_grant = await call(registry, "automation.save_routine", {"name": "X", "steps": STEPS}, "b5")
    assert isinstance(no_grant, Denied) and no_grant.reason.startswith("permission_not_granted")


async def test_list_and_run_tools_with_summaries_in_three_languages(
    registry: PluginRegistry, test_tools: Recorder
) -> None:
    empty = await call(registry, "automation.list_routines", {}, "l0")
    assert empty.summary == "You have no routines yet." and empty.result.routines == []
    await call(
        registry,
        "automation.save_routine",
        {
            "name": "Morning",
            "steps": [STEPS[0]],
            "trigger": {"kind": "weekly", "days": ["mon", "fri"], "time": "07:30"},
        },
        "s1",
    )
    await call(registry, "automation.save_routine", {"name": "Notes", "steps": [STEPS[1]]}, "s2")
    for lang, expect in (
        ("en", "You have 2 routines: Morning, Notes."),
        ("hi", "आपके 2 रूटीन हैं: Morning, Notes।"),
        ("hinglish", "Aapke 2 routines hain: Morning, Notes."),
    ):
        done = await call(registry, "automation.list_routines", {}, f"l-{lang}", lang=lang)
        assert done.summary == expect
    shown = await ctx(registry).working_set("routines")
    assert [r["name"] for r in shown] == ["Morning", "Notes"]  # "the second one" resolves next turn

    ran = await call(registry, "automation.run_routine", {"routine": "morning"}, "r1")
    assert (
        isinstance(ran, Completed)
        and ran.result.status == "completed"
        and ran.summary == "Ran Morning: all 1 steps are done."
    )
    hi = await call(registry, "automation.run_routine", {"routine": "Morning"}, "r2", lang="hi")
    assert "चल गया" in hi.summary and "1" in hi.summary
    waiting = await call(registry, "automation.run_routine", {"routine": "Notes"}, "r3", lang="hinglish")
    assert (
        waiting.result.status == "awaiting_approval"
        and "intezaar" in waiting.summary
        and test_tools.writes == []
    )
    busy = await call(registry, "automation.run_routine", {"routine": "Notes"}, "r4")
    assert isinstance(busy, Failed) and busy.error == "routine_busy"
    missing = await call(registry, "automation.run_routine", {"routine": "Nope"}, "r5")
    assert isinstance(missing, Failed) and missing.error == "routine_not_found"
    nums = {n for n in _NUM.findall(waiting.summary)}
    assert nums <= {n for n in _NUM.findall(waiting.result.model_dump_json())}


async def test_run_approval_view_names_the_routine(
    registry: PluginRegistry, paired_device: PairedDevice
) -> None:
    await call(registry, "automation.save_routine", {"name": "Morning", "steps": [STEPS[0]]}, "s1")
    pending = await call(
        registry,
        "automation.run_routine",
        {"routine": "Morning", "params": {"who": "Asha"}},
        "r1",
        user_initiated=False,
        device_id=paired_device.device_id,
    )
    assert isinstance(pending, NeedsApproval) and pending.request.title == "Run routine Morning"
    assert {d.label: d.value for d in pending.request.details} == {"routine": "Morning", "param who": "Asha"}


# ---------------------------------------------------------------- intents


def route(text: str, shown: list[dict[str, str]] | None = None) -> tuple[str, dict[str, Any]] | None:
    context = IntentContext(lang="en", now=NOW, working_sets={"routines": shown or []})
    for spec in sorted(build_intents(), key=lambda s: -s.priority):
        slots = spec.extract(text, context)
        if slots is not None:
            return spec.name, slots
    return None


SHOWN = [{"id": "rtn_a", "name": "Morning"}, {"id": "rtn_b", "name": "Evening"}]
CASES = [
    ("what are my routines", None, ("automation.list_routines", {})),
    ("show my routines", None, ("automation.list_routines", {})),
    ("mere routines dikhao", None, ("automation.list_routines", {})),
    ("मेरे रूटीन दिखाओ", None, ("automation.list_routines", {})),
    ("run my morning routine", None, ("automation.run_routine", {"routine": "morning"})),
    ("start the gym routine", None, ("automation.run_routine", {"routine": "gym"})),
    ("morning routine chalao", None, ("automation.run_routine", {"routine": "morning"})),
    ("सुबह का रूटीन चलाओ", None, ("automation.run_routine", {"routine": "सुबह का"})),
    ("run the second one", SHOWN, ("automation.run_routine", {"routine": "rtn_b"})),
    ("doosra wala routine chalao", SHOWN, ("automation.run_routine", {"routine": "rtn_b"})),
    ("पहला रूटीन चलाओ", SHOWN, ("automation.run_routine", {"routine": "rtn_a"})),
    ("what is the weather", None, None),
    ("run 5k plan", None, None),
    ("show me the second one", SHOWN, None),
]


@pytest.mark.parametrize(("text", "shown", "want"), CASES)
def test_intents_three_languages(
    text: str, shown: list[dict[str, str]] | None, want: tuple[str, dict[str, Any]] | None
) -> None:
    assert route(text, shown) == want


def test_the_plugin_registers_both_intents_with_three_language_keywords(registry: PluginRegistry) -> None:
    specs = [s for s in registry.intents.all() if s.name.startswith("automation.")]
    assert {s.tool for s in specs} == {"automation.list_routines", "automation.run_routine"}
    assert all(s.keywords[lang] for s in specs for lang in ("en", "hi", "hinglish")) and all(
        s.examples for s in specs
    )


# ---------------------------------------------------------------- routes


async def test_routes_crud_run_and_resume(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry, test_tools: Recorder
) -> None:
    h = paired_device.headers
    assert (await client.get("/v1/automations")).status_code == 401
    body = {"name": "Notes", "steps": STEPS, "trigger": {"kind": "daily", "time": "20:00"}}
    saved = await client.post("/v1/automations", json=body, headers=h)
    assert saved.status_code == 200, saved.text
    routine = saved.json()
    assert (
        routine["created"] is True
        and routine["next_run_at"] == "2026-11-13T14:30:00Z"
        and routine["trigger"]["time"] == "20:00"
    )
    again = (await client.post("/v1/automations", json={**body, "name": "NOTES"}, headers=h)).json()
    assert again["id"] == routine["id"] and again["created"] is False
    assert [r["name"] for r in (await client.get("/v1/automations", headers=h)).json()] == ["Notes"]
    assert (await client.get("/v1/automations/notes", headers=h)).json()["id"] == routine["id"]
    assert (await client.get("/v1/automations/nope", headers=h)).json()["code"] == "routine_not_found"

    bad = await client.post(
        "/v1/automations",
        json={**body, "name": "Bad", "steps": [{"tool": "test.missing", "args": {}}]},
        headers=h,
    )
    assert bad.status_code == 422 and bad.json()["code"] == "routine_invalid"
    recursive = await client.post(
        "/v1/automations",
        json={**body, "name": "Bad", "steps": [{"tool": "automation.run_routine", "args": {}}]},
        headers=h,
    )
    assert recursive.status_code == 422
    assert (
        await client.post(
            "/v1/automations",
            json={**body, "name": "Bad", "trigger": {"kind": "interval", "every_minutes": 1}},
            headers=h,
        )
    ).status_code == 422

    run = (await client.post(f"/v1/automations/{routine['id']}/run", headers=h)).json()
    assert (
        run["status"] == "awaiting_approval"
        and run["pending"]["kind"] == "approval"
        and test_tools.writes == []
    )
    assert (await client.post("/v1/automations/notes/run", headers=h)).json()["code"] == "routine_busy"
    request = (await registry.service("approvals").list_pending())[0]
    empty = await client.post(f"/v1/automations/runs/{run['id']}/resume", json={}, headers=h)
    assert empty.status_code == 400 and empty.json()["code"] == "resume_body_invalid"
    decision = paired_device.signer.sign_approval(request).model_dump(mode="json")
    resumed = (
        await client.post(f"/v1/automations/runs/{run['id']}/resume", json={"approval": decision}, headers=h)
    ).json()
    assert resumed["status"] == "completed" and [w.note for w in test_tools.writes] == ["buy milk"]
    assert (await client.get(f"/v1/automations/runs/{run['id']}", headers=h)).json()["status"] == "completed"
    history = (await client.get(f"/v1/automations/{routine['id']}/runs", headers=h)).json()
    assert [r["id"] for r in history] == [run["id"]] and history[0]["step_log"][1]["status"] == "completed"
    assert (await client.get("/v1/automations/runs/run_nope", headers=h)).json()["code"] == "run_not_found"

    off = (await client.patch(f"/v1/automations/{routine['id']}", json={"enabled": False}, headers=h)).json()
    assert off["enabled"] is False and off["next_run_at"] is None
    assert (await client.post(f"/v1/automations/{routine['id']}/run", headers=h)).json()[
        "code"
    ] == "routine_disabled"
    assert (await client.delete(f"/v1/automations/{routine['id']}", headers=h)).status_code == 204
    assert (await client.get("/v1/automations", headers=h)).json() == []


async def test_cancel_route_and_permissions(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    h = paired_device.headers
    routine = (
        await client.post("/v1/automations", json={"name": "Notes", "steps": [STEPS[1]]}, headers=h)
    ).json()
    run = (await client.post(f"/v1/automations/{routine['id']}/run", headers=h)).json()
    assert (await client.post(f"/v1/automations/runs/{run['id']}/cancel", headers=h)).json()[
        "status"
    ] == "cancelled"
    for key, call_ in (
        ("automation.read", client.get("/v1/automations", headers=h)),
        ("automation.manage", client.post("/v1/automations", json={"name": "Z", "steps": STEPS}, headers=h)),
        ("automation.run", client.post(f"/v1/automations/{routine['id']}/run", headers=h)),
    ):
        await registry.service("permissions").set(key, False)
        response = await call_
        assert response.status_code == 403 and response.json()["code"] == f"permission_not_granted:{key}"
