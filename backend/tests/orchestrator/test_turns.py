"""Turns end to end through the supervisor graph: routing, parallel work, synthesis, guard."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select

from app.core.types import AgentId, DataClass, PrivacyMode, TaskClass
from app.plugins import PluginRegistry
from app.providers.types import ChatResponse, NoPermittedModel, ProviderError, ToolCall, Usage
from app.security.models import AuditRow
from tests.fakes.gateway import FakeGateway
from tests.orchestrator.conftest import Ask, cloud_mode, of, text_of
from tests.orchestrator.toolkit import INJECTION, Toolbox


async def test_english_turn_is_deterministic_in_strict_private_mode(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    events = await ask("How much did I spend last month?")
    kinds = [event.type for event in events]
    assert kinds == [
        "turn_started", "route", "agent_started", "tool_started", "tool_finished", "card",
        "agent_finished", "text_delta", "turn_completed",
    ]  # fmt: skip
    assert events[0].privacy_mode is PrivacyMode.STRICT_PRIVATE
    route = of(events, "route")[0]
    assert route.agents == [AgentId.FINANCE] and route.engine == "deterministic"
    assert route.data_classes == [DataClass.FINANCIAL]
    assert text_of(events) == "You spent ₹12450.50 across 14 transactions in 2026-10."
    done = of(events, "turn_completed")[0]
    assert done.language == "en" and done.data_classes == [DataClass.FINANCIAL]
    assert done.cloud_voice_allowed is False  # strict private: the reply is spoken on device
    assert done.usage.tool_calls == 1 and done.usage.model_calls == 0
    assert gateway.requests == []  # no model was asked anything
    async with registry.service("session_factory")() as session:
        actions = list((await session.scalars(select(AuditRow.action))).all())
    assert "turn.completed" in actions and "tool.run" in actions


async def test_hindi_and_hinglish_turns_answer_in_the_same_language(ask: Ask, box: Toolbox) -> None:
    hindi = await ask("पिछले महीने कितना खर्च हुआ?")
    assert of(hindi, "turn_completed")[0].language == "hi"
    assert text_of(hindi) == "आपने 2026-10 में 14 लेन-देन में ₹12450.50 खर्च किए।"
    hinglish = await ask("pichhle mahine kitna kharcha hua")
    assert of(hinglish, "turn_completed")[0].language == "hinglish"
    assert text_of(hinglish) == "Aapne 2026-10 mein 14 transactions mein ₹12450.50 kharch kiye."


async def test_compound_request_runs_two_agents_in_parallel(ask: Ask, box: Toolbox) -> None:
    box.rendezvous = True
    events = await ask("how much did I spend and find some songs")
    assert of(events, "route")[0].agents == [AgentId.FINANCE, AgentId.MUSIC]
    assert box.overlapped, "both tool handlers must be running at the same time"
    kinds = [event.type for event in events]
    first_finish = kinds.index("agent_finished")
    assert kinds[:first_finish].count("agent_started") == 2  # both started before either finished
    assert text_of(events) == (
        "You spent ₹12450.50 across 14 transactions in 2026-10. I found 3 songs; the first is Lag Ja Gale."
    )
    assert of(events, "text_delta")[0].text.endswith("2026-10. ")  # sentence chunks
    assert of(events, "turn_completed")[0].usage.tool_calls == 2


async def test_unmatched_request_without_a_model_says_so(
    ask: Ask, box: Toolbox, gateway: FakeGateway
) -> None:
    events = await ask("tell me a joke about monsoon")
    route = of(events, "route")[0]
    assert route.agents == [AgentId.PERSONAL_ASSISTANT] and route.engine == "deterministic"
    assert "could not match" in text_of(events)
    assert gateway.requests == []
    hindi = await ask("मानसून पर एक चुटकुला सुनाओ")
    assert "मॉडल" in text_of(hindi)


async def test_cloud_mode_model_phrases_the_answer(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    await cloud_mode(registry)
    gateway.push(
        ChatResponse(
            text="I found 3 songs, starting with Lag Ja Gale.", usage=Usage(input_tokens=40, output_tokens=12)
        )
    )
    events = await ask("find some old songs", app_state={"response_length": "detailed"})
    assert text_of(events) == "I found 3 songs, starting with Lag Ja Gale."
    (request,) = gateway.requests
    assert request.task is TaskClass.SUMMARIZATION and request.agent is AgentId.VOICE
    assert request.privacy_mode is PrivacyMode.CLOUD_INTELLIGENCE
    assert request.data_classes == frozenset({DataClass.PUBLIC, DataClass.PERSONAL})
    assert "English" in request.messages[0].content and "short paragraph" in request.messages[0].content
    assert '"count":3' in request.messages[1].content and request.messages[1].role == "user"
    done = of(events, "turn_completed")[0]
    assert done.cloud_voice_allowed is True
    assert (done.usage.model_calls, done.usage.input_tokens, done.usage.output_tokens) == (1, 40, 12)


async def test_financial_results_stay_local_until_the_owner_grants_them(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    await cloud_mode(registry)
    events = await ask("how much did I spend")
    assert gateway.requests == []  # financial data is not granted to cloud models
    assert text_of(events).startswith("You spent ₹12450.50")
    assert of(events, "turn_completed")[0].cloud_voice_allowed is False

    await registry.service("permissions").set("cloud.financial", True)
    gateway.push("Last month you spent ₹12,450.50 over 14 transactions.")
    granted = await ask("how much did I spend")
    assert text_of(granted) == "Last month you spent ₹12,450.50 over 14 transactions."
    assert of(granted, "turn_completed")[0].cloud_voice_allowed is True


async def test_numeric_guard_discards_an_invented_number(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    await cloud_mode(registry)
    gateway.push("I found 7 songs for you, the best is Lag Ja Gale.")  # the tool said 3
    events = await ask("find some old songs")
    assert text_of(events) == "I found 3 songs; the first is Lag Ja Gale."
    assert len(gateway.requests) == 1


async def test_model_failure_falls_back_to_summaries(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    await cloud_mode(registry)
    gateway.push(ProviderError("unavailable", "down"))
    assert text_of(await ask("find some old songs")) == "I found 3 songs; the first is Lag Ja Gale."
    gateway.push(NoPermittedModel(TaskClass.SUMMARIZATION))
    assert text_of(await ask("find some old songs")) == "I found 3 songs; the first is Lag Ja Gale."


async def test_follow_up_turn_sees_the_working_set(ask: Ask, box: Toolbox) -> None:
    first = await ask("search for milk")
    conversation_id = first[0].conversation_id
    assert text_of(first) == "I found 3 options for milk."
    second = await ask("add the second one", conversation_id=conversation_id)
    assert of(second, "route")[0].agents == [AgentId.SHOPPING]
    assert text_of(second) == "Added Mother Dairy Toned Milk 1 L to your basket."
    hinglish = await ask("teesra wala add karo", conversation_id=conversation_id)
    assert text_of(hinglish) == "Nandini Milk 500 ml aapki basket mein add kar diya."
    # Another conversation has no list to pick from.
    other = await ask("add the second one")
    assert box.calls["basket"] == 2 and "could not match" in text_of(other)


async def test_model_routing_only_when_unsure_and_permitted(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    await cloud_mode(registry)
    gateway.push(
        {"agent": "music", "intent": "test.tracks", "confidence": 0.8},
        "Here are 3 tracks, first Lag Ja Gale.",
    )
    events = await ask("put on something soothing")
    route = of(events, "route")[0]
    assert route.engine == "cloud_model" and route.agents == [AgentId.MUSIC]
    assert "test.tracks" in route.reason
    assert gateway.requests[0].task is TaskClass.INTENT_CLASSIFICATION
    assert gateway.requests[0].response_schema is not None
    assert "test.tracks (music)" in gateway.requests[0].messages[0].content
    assert box.calls["tracks"] == 1 and text_of(events) == "Here are 3 tracks, first Lag Ja Gale."

    # A confident local match never asks the routing model.
    before = len(gateway.requests)
    gateway.push("I found 3 songs; first is Lag Ja Gale.")
    await ask("find some songs")
    assert [r.task for r in gateway.requests[before:]] == [TaskClass.SUMMARIZATION]

    # An invalid suggestion falls back to the personal assistant.
    gateway.push({"agent": "nobody"}, "Namaste! How can I help?")
    fallback = await ask("hmm what now")
    assert of(fallback, "route")[0].agents == [AgentId.PERSONAL_ASSISTANT]
    assert text_of(fallback) == "Namaste! How can I help?"


async def test_model_path_sees_only_allowlisted_tools_and_wrapped_results(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    await cloud_mode(registry)
    gateway.push(
        {"agent": "browser_research", "confidence": 0.9},
        ChatResponse(
            tool_calls=(
                ToolCall(id="c1", name="test__fetch_page", arguments={"url": "https://example.test/t"}),
                ToolCall(id="c2", name="test.send_message", arguments={"to": "x", "body": "y"}),
            )
        ),
        "Train 12951 departs at 16:35.",
    )
    events = await ask("when does the Rajdhani leave")
    loop_request = gateway.requests[1]
    assert [tool.name for tool in loop_request.tools] == ["test__fetch_page"]  # the agent's allowlist only
    final_request = gateway.requests[2]
    system = [m for m in final_request.messages if m.role == "system"]
    assert len(system) == 1 and INJECTION not in system[0].content and "untrusted" in system[0].content
    tool_messages = [m for m in final_request.messages if m.role == "tool"]
    assert tool_messages[0].content.startswith('<untrusted source="test.fetch_page">')
    assert INJECTION in tool_messages[0].content
    assert '"code": "agent_not_allowed"' in tool_messages[1].content  # denied by the executor, not run
    assert "send" not in box.calls
    finished = of(events, "tool_finished")
    assert [f.ok for f in finished] == [True, False]
    assert text_of(events) == "Train 12951 departs at 16:35."
    done = of(events, "turn_completed")[0]
    assert done.usage.model_calls == 3 and done.usage.tool_calls == 2


async def test_model_path_draft_with_invented_number_is_replaced(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    await cloud_mode(registry)
    gateway.push(
        {"agent": "music", "confidence": 0.7},
        ChatResponse(tool_calls=(ToolCall(id="c1", name="test__find_tracks", arguments={"query": "calm"}),)),
        "I found 25 calm songs.",
    )
    events = await ask("something calm please")
    assert text_of(events) == "I found 3 songs; the first is Lag Ja Gale."


async def test_memory_service_is_optional_and_used_when_present(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    class FakeMemory:
        def __init__(self) -> None:
            self.recalls: list[tuple[str, int]] = []
            self.proposals: list[dict[str, Any]] = []

        async def recall(self, query: str, *, limit: int, ctx: Any) -> list[dict[str, Any]]:
            self.recalls.append((query, limit))
            return [
                {"id": "mem_1", "text": "Prefers old Hindi film songs", "sensitivity": "personal"},
                {"id": "mem_2", "text": "locker code", "sensitivity": "secret"},
            ]

        async def propose_from_turn(self, *, user_text: str, assistant_text: str, ctx: Any) -> None:
            self.proposals.append({"user": user_text, "assistant": assistant_text, "agent": ctx.agent})

    memory = FakeMemory()
    registry.provide("memory", memory)
    await cloud_mode(registry)
    gateway.push({"agent": "personal_assistant", "confidence": 0.6}, "You like old Hindi film songs.")
    events = await ask("what do I usually enjoy listening to")
    assert memory.recalls == [("what do I usually enjoy listening to", 5)]
    chat = gateway.requests[1]
    notes = chat.messages[1].content
    assert "Prefers old Hindi film songs" in notes and "locker code" not in notes  # secrets never recalled
    assert chat.messages[1].role == "user"
    assert memory.proposals == [
        {
            "user": "what do I usually enjoy listening to",
            "assistant": text_of(events),
            "agent": AgentId.MEMORY,
        }
    ]
    # A tainted turn (it read a web page) proposes nothing.
    await ask("read the page")
    assert len(memory.proposals) == 1


async def test_security_agent_explains_policy_in_each_language(
    ask: Ask, box: Toolbox, gateway: FakeGateway, registry: PluginRegistry
) -> None:
    why = await ask("Why do you need my approval for test.send_message?")
    assert of(why, "route")[0].agents == [AgentId.SECURITY]
    assert "always needs your confirmation" in text_of(why)
    hinglish = await ask("private mode kya hai")
    assert text_of(hinglish).startswith("Private mode on hai: cloud models ko kuch nahi bheja jaata")
    hindi = await ask("प्राइवेट मोड क्या है?")
    assert text_of(hindi).startswith("प्राइवेट मोड चालू है")
    assert gateway.requests == []
    # Explaining changed nothing.
    assert await registry.service("privacy_state").stored_mode() is PrivacyMode.STRICT_PRIVATE
    assert await registry.service("approvals").list_pending() == []
