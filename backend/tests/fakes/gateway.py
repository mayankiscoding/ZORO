"""FakeGateway: a scripted stand-in for `app.providers.gateway.ModelGateway` in other packages' tests.

    gw = FakeGateway(["first reply", ChatResponse(text="", tool_calls=(ToolCall(id="c1", name="x"),)),
                      NoPermittedModel(TaskClass.ROUTINE_CHAT)])
    resp = await gw.chat(req)          # pops the next scripted item; exceptions are raised
    gw.requests                        # every ChatRequest received, in order
    await gw.permitted(task, classes, mode)   # mirrors ModelGateway.permitted (see `permit`)
    await gw.turn_cost_usd("turn_1")          # mirrors ModelGateway.turn_cost_usd (see `turn_costs`)

Embeddings use the deterministic `local-hash-v1` embedder, so vector tests are stable.
"""

from __future__ import annotations

import json
from collections import deque
from collections.abc import AsyncIterator, Callable, Iterable
from decimal import Decimal
from typing import Any

from app.core.types import DataClass, PrivacyMode, TaskClass
from app.providers.embedding import LOCAL_HASH_DIMS, LOCAL_HASH_MODEL_ID, local_hash_embed
from app.providers.types import ChatChunk, ChatRequest, ChatResponse, EmbeddingResult, Usage
from app.schemas.security import ModelRouteInfo

Scripted = ChatResponse | str | dict[str, Any] | BaseException
PermitRule = bool | Callable[[TaskClass, frozenset[DataClass], PrivacyMode], bool]


class FakeGateway:
    def __init__(
        self,
        script: Iterable[Scripted] = (),
        *,
        default: Scripted | None = None,
        permit: PermitRule = True,
    ) -> None:
        self.script: deque[Scripted] = deque(script)
        self.default = default
        self.permit: PermitRule = permit
        self.requests: list[ChatRequest] = []
        self.embed_calls: list[tuple[list[str], frozenset[DataClass], PrivacyMode]] = []
        self.permit_calls: list[tuple[TaskClass, frozenset[DataClass], PrivacyMode]] = []
        self.turn_costs: dict[str, Decimal] = {}

    async def permitted(
        self,
        task: TaskClass,
        data_classes: frozenset[DataClass],
        mode: PrivacyMode,
        capability: str = "chat",
    ) -> bool:
        self.permit_calls.append((task, data_classes, mode))
        rule = self.permit
        return rule if isinstance(rule, bool) else bool(rule(task, data_classes, mode))

    async def turn_cost_usd(self, turn_id: str) -> Decimal:
        return self.turn_costs.get(turn_id, Decimal(0))

    def push(self, *items: Scripted) -> None:
        self.script.extend(items)

    def _next(self, req: ChatRequest) -> ChatResponse:
        self.requests.append(req)
        if self.script:
            item = self.script.popleft()
        elif self.default is not None:
            item = self.default
        else:
            raise AssertionError(f"FakeGateway: no scripted response left for task {req.task.value}")
        if isinstance(item, BaseException):
            raise item
        if isinstance(item, ChatResponse):
            return item
        if isinstance(item, dict):  # structured output
            return ChatResponse(text=json.dumps(item), parsed=item, provider="fake", model="fake")
        return ChatResponse(text=item, provider="fake", model="fake")

    async def chat(self, req: ChatRequest) -> ChatResponse:
        return self._next(req)

    async def stream(self, req: ChatRequest) -> AsyncIterator[ChatChunk]:
        resp = self._next(req)
        for word in resp.text.split(" ") if resp.text else []:
            yield ChatChunk(delta=word + " ", provider=resp.provider, model=resp.model)
        if resp.tool_calls:
            yield ChatChunk(tool_calls=resp.tool_calls, provider=resp.provider, model=resp.model)
        yield ChatChunk(
            done=True,
            finish_reason=resp.finish_reason,
            usage=resp.usage or Usage(),
            provider=resp.provider,
            model=resp.model,
        )

    async def embed_with_model(
        self, texts: list[str], data_classes: frozenset[DataClass], privacy_mode: PrivacyMode
    ) -> EmbeddingResult:
        self.embed_calls.append((list(texts), data_classes, privacy_mode))
        vecs = local_hash_embed(texts)
        return EmbeddingResult(
            model=LOCAL_HASH_MODEL_ID, dims=LOCAL_HASH_DIMS, vectors=tuple(tuple(v) for v in vecs)
        )

    async def embed(
        self,
        texts: list[str],
        data_classes: frozenset[DataClass],
        privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE,
    ) -> list[list[float]]:
        result = await self.embed_with_model(texts, data_classes, privacy_mode)
        return [list(v) for v in result.vectors]

    async def route_info(
        self, privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE
    ) -> list[ModelRouteInfo]:
        return [ModelRouteInfo(task=t, models=[], active_model=None, locality=None) for t in TaskClass]

    def health(self) -> dict[str, dict[str, Any]]:
        return {}
