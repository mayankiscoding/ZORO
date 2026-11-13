"""AgentRunner: the deterministic plan path and the bounded model loop."""

from __future__ import annotations

from dataclasses import replace
from typing import Any

from app.agents.access import external_allowed, model_permitted
from app.agents.calls import Budget, PlannedCall
from app.agents.runner import AgentRunner
from app.core.types import AgentId, DataClass, PrivacyMode, TaskClass
from app.plugins import PluginRegistry
from app.providers.types import ChatResponse, NoPermittedModel, ProviderError, ToolCall, Usage
from tests.agents.conftest import Recorder, make_env
from tests.fakes.gateway import FakeGateway
from tests.orchestrator.toolkit import INJECTION, Toolbox


def call(n: int, agent: AgentId, tool: str, **args: Any) -> PlannedCall:
    return PlannedCall(call_id=f"turn_agents.p{n}", agent=agent, tool=tool, args=args, user_initiated=True)


async def test_plan_runs_read_only_calls_and_queues_the_rest(
    registry: PluginRegistry, box: Toolbox, recorder: Recorder
) -> None:
    runner: AgentRunner = registry.service("agent_runner")
    run = await runner.run_plan(
        make_env(recorder),
        AgentId.SHOPPING,
        [
            call(0, AgentId.SHOPPING, "test.search_products", query="milk"),
            call(1, AgentId.SHOPPING, "test.add_to_basket", ref="p1", name="Amul Gold Milk 1 L"),
        ],
    )
    assert [r["status"] for r in run.results] == ["completed"] and run.results[0][
        "summary"
    ] == "I found 3 options for milk."
    assert run.results[0]["data_classes"] == ["public"] and run.data_classes == {DataClass.PUBLIC}
    assert [q["tool"] for q in run.queued] == ["test.add_to_basket"] and "basket" not in box.calls
    assert recorder.kinds == ["tool_started", "tool_finished"] and run.tool_calls == 1 and run.ok
    # The tool wrote the working set through ctx.state.
    assert len(await registry.service("conversation_state").working_set("conv_agents", "products")) == 3


async def test_plan_failures_are_recorded_not_raised(
    registry: PluginRegistry, box: Toolbox, recorder: Recorder
) -> None:
    runner: AgentRunner = registry.service("agent_runner")
    run = await runner.run_plan(
        make_env(recorder),
        AgentId.FINANCE,
        [
            call(0, AgentId.FINANCE, "test.find_tracks", query="x"),  # not on finance's allowlist
            call(1, AgentId.FINANCE, "test.nope"),
            call(2, AgentId.FINANCE, "test.spending_summary", month=["bad"]),
        ],
    )
    assert [(r["status"], r["code"]) for r in run.results] == [
        ("denied", "agent_not_allowed"),
        ("denied", "unknown_tool"),
        ("failed", "invalid_arguments"),
    ]
    assert box.calls == {}


async def test_taint_is_one_way_inside_a_run_and_budget_stops_it(
    registry: PluginRegistry, box: Toolbox, recorder: Recorder
) -> None:
    runner: AgentRunner = registry.service("agent_runner")
    env = make_env(recorder)
    run = await runner.run_plan(
        env, AgentId.BROWSER_RESEARCH, [call(0, AgentId.BROWSER_RESEARCH, "test.fetch_page", url="u")]
    )
    assert (
        run.tainted and run.results[0]["untrusted"] and env.tainted is False
    )  # the turn state is updated by the graph

    tight = make_env(recorder, budget=Budget(max_tool_calls=1))
    stopped = await runner.run_plan(
        tight,
        AgentId.MUSIC,
        [
            call(1, AgentId.MUSIC, "test.find_tracks", query="a"),
            call(2, AgentId.MUSIC, "test.find_tracks", query="b"),
        ],
    )
    assert stopped.stop == "tool_calls" and len(stopped.results) == 1 and not stopped.ok


async def test_model_loop_allowlist_wrapping_and_executor(
    registry: PluginRegistry, box: Toolbox, gateway: FakeGateway, recorder: Recorder
) -> None:
    runner: AgentRunner = registry.service("agent_runner")
    gateway.push(
        ChatResponse(
            tool_calls=(
                ToolCall(id="a", name="test__fetch_page", arguments={"url": "https://example.test"}),
            ),
            usage=Usage(input_tokens=30, output_tokens=5),
        ),
        ChatResponse(text="The train leaves at 16:35.", usage=Usage(input_tokens=60, output_tokens=9)),
    )
    env = make_env(recorder, lang="hinglish")
    recall = [
        {"text": "Lives in Pune", "data_class": "sensitive"},
        {"text": "Blood pressure is high", "data_class": "health"},  # not granted to cloud models
    ]
    await registry.service("permissions").set("cloud.sensitive", True)
    run = await runner.run_model(env, AgentId.BROWSER_RESEARCH, "train kab hai", recall=recall)
    assert run.engine == "model" and run.text == "The train leaves at 16:35." and run.tainted
    assert (run.model_calls, run.input_tokens, run.output_tokens, run.tool_calls) == (2, 90, 14, 1)
    assert env.budget.tokens == 104 and env.budget.tool_calls == 1
    first, second = gateway.requests
    assert [tool.name for tool in first.tools] == ["test__fetch_page"]
    assert first.task is TaskClass.CODING_RESEARCH and first.agent is AgentId.BROWSER_RESEARCH
    assert first.data_classes == frozenset({DataClass.PERSONAL, DataClass.SENSITIVE})  # recall is labelled
    assert first.messages[0].role == "system" and "Hinglish" in first.messages[0].content
    assert "Lives in Pune" in first.messages[1].content and first.messages[1].role == "user"
    assert all("Blood pressure" not in m.content for m in first.messages)  # dropped, the answer still happens
    assert second.data_classes >= {DataClass.PUBLIC, DataClass.PERSONAL, DataClass.SENSITIVE}
    roles = [m.role for m in second.messages]
    assert roles == ["system", "user", "user", "assistant", "tool"]
    assert second.messages[-1].content.startswith('<untrusted source="test.fetch_page">')
    assert all(INJECTION not in m.content for m in second.messages if m.role == "system")
    assert recorder.kinds == ["tool_started", "tool_finished"]


async def test_model_loop_is_bounded(registry: PluginRegistry, box: Toolbox, recorder: Recorder) -> None:
    again = ChatResponse(
        tool_calls=(ToolCall(id="x", name="test__find_tracks", arguments={"query": "more"}),)
    )
    gateway = FakeGateway(default=again)
    registry.provide("gateway", gateway)
    runner: AgentRunner = registry.service("agent_runner")
    spec = registry.service("agents").get(AgentId.MUSIC)
    run = await runner.run_model(make_env(recorder), AgentId.MUSIC, "keep going")
    assert len(gateway.requests) == spec.max_tool_iterations + 1  # never a loop
    assert gateway.requests[-1].tools == ()  # the last round must answer in words
    assert box.calls["tracks"] == spec.max_tool_iterations and run.note == "iterations" and not run.text


async def test_model_side_effects_are_queued_and_marked_model_chosen(
    registry: PluginRegistry, box: Toolbox, gateway: FakeGateway, recorder: Recorder
) -> None:
    runner: AgentRunner = registry.service("agent_runner")
    gateway.push(
        ChatResponse(
            tool_calls=(ToolCall(id="a", name="test__send_message", arguments={"to": "Asha", "body": "hi"}),)
        ),
        "I have prepared the message; it is waiting for your approval.",
    )
    run = await runner.run_model(make_env(recorder), AgentId.COMMUNICATION, "tell Asha hi")
    assert "send" not in box.calls and recorder.events == []
    assert [PlannedCall.from_json(item) for item in run.queued] == [
        PlannedCall(
            call_id="turn_agents.communication.m0.0",
            agent=AgentId.COMMUNICATION,
            tool="test.send_message",
            args={"to": "Asha", "body": "hi"},
            user_initiated=False,  # a model chose it
        )
    ]
    assert '"status": "queued"' in gateway.requests[1].messages[-1].content


async def test_model_unavailable_paths(
    registry: PluginRegistry, box: Toolbox, gateway: FakeGateway, recorder: Recorder
) -> None:
    runner: AgentRunner = registry.service("agent_runner")
    strict = make_env(recorder, privacy_mode=PrivacyMode.STRICT_PRIVATE)
    run = await runner.run_model(strict, AgentId.PERSONAL_ASSISTANT, "hello")
    assert run.note == "no_model" and gateway.requests == [] and run.ok  # zero gateway calls

    catalog = registry.service("agents")
    catalog.override(
        replace(
            catalog.get(AgentId.PERSONAL_ASSISTANT),
            retry=replace(catalog.get(AgentId.PERSONAL_ASSISTANT).retry, backoff_s=0),
        )
    )
    gateway.push(ProviderError("unavailable", "blip"), "Hello!")
    retried = await runner.run_model(make_env(recorder), AgentId.PERSONAL_ASSISTANT, "hello")
    assert retried.text == "Hello!" and retried.model_calls == 1 and len(gateway.requests) == 2

    gateway.push(ProviderError("auth", "bad key"))
    broken = await runner.run_model(make_env(recorder), AgentId.PERSONAL_ASSISTANT, "hello")
    assert broken.note == "model_error" and not broken.ok and not broken.text

    gateway.push(NoPermittedModel(TaskClass.ROUTINE_CHAT))
    refused = await runner.run_model(make_env(recorder), AgentId.PERSONAL_ASSISTANT, "hello")
    assert refused.note == "no_model"


async def test_model_permitted_rules(registry: PluginRegistry) -> None:
    cloud, strict = PrivacyMode.CLOUD_INTELLIGENCE, PrivacyMode.STRICT_PRIVATE
    personal = {DataClass.PERSONAL}
    assert not await model_permitted(registry, TaskClass.ROUTINE_CHAT, personal, cloud)  # no gateway at all

    class Listing:
        def __init__(self) -> None:
            self.asked: list[tuple[Any, ...]] = []
            self.allow = True

        async def candidates(self, task: Any, classes: Any, mode: Any, capability: str) -> list[str]:
            self.asked.append((task, classes, mode, capability))
            if not self.allow:
                raise NoPermittedModel(task)
            return ["local-model"]

    listing = Listing()
    registry.provide("gateway", listing)
    # A gateway that can list candidates decides: a local model works in strict private mode.
    assert await model_permitted(registry, TaskClass.ROUTINE_CHAT, {DataClass.FINANCIAL}, strict)
    assert listing.asked[0][3] == "chat"
    listing.allow = False
    assert not await model_permitted(registry, TaskClass.ROUTINE_CHAT, personal, cloud)
    assert not await model_permitted(registry, TaskClass.ROUTINE_CHAT, {DataClass.SECRET}, cloud)

    assert await external_allowed(registry, cloud, personal)
    assert not await external_allowed(registry, cloud, {DataClass.HEALTH})
    assert not await external_allowed(registry, strict, {DataClass.PUBLIC})
    await registry.service("permissions").set("cloud.health", True)
    assert await external_allowed(registry, cloud, {DataClass.HEALTH})
    await registry.service("kill_switch").set(True)
    assert not await external_allowed(registry, cloud, personal)
    listing.allow = True
    assert not await model_permitted(registry, TaskClass.ROUTINE_CHAT, personal, cloud)
