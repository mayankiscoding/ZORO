"""ModelGateway: the only path from ZORO to a language model.

Per request: route candidates for the task -> drop disabled providers -> `decide_egress` (privacy is
enforced here, in code) -> redact when the decision says so -> trim to the model's context window ->
call with timeout and retry (exponential backoff + jitter) -> per-model circuit breaker and 429 handling
-> fall back to the next candidate -> record a usage event. Nothing permitted -> `NoPermittedModel`.
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import time
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

import httpx

from app.core.types import DataClass, Locality, PrivacyMode, TaskClass
from app.providers.adapters import AdapterRequest, GeminiAdapter, OpenAICompatAdapter, ProviderAdapter
from app.providers.config import ConfigSource, ModelEntry, ResolvedProvider
from app.providers.embedding import LOCAL_HASH_DIMS, LOCAL_HASH_MODEL_ID, local_hash_embed
from app.providers.guard import (
    KILL_SWITCH_REASON,
    EgressOverrides,
    KillSwitchState,
    blocked_by_kill_switch,
    clamp_mode,
    kill_switch_on,
)
from app.providers.redact import redact_messages
from app.providers.resilience import CircuitBreaker, RetryPolicy
from app.providers.trim import input_budget, trim_messages
from app.providers.types import (
    ChatChunk,
    ChatRequest,
    ChatResponse,
    EgressDenied,
    EmbeddingResult,
    NoPermittedModel,
    ProviderError,
)
from app.providers.usage import MemoryUsageSink, UsageRecord, UsageSink, cost_micro_usd
from app.schemas.security import ModelRouteInfo
from app.security.egress import DEFAULT_EXTERNAL_CLASSES, decide_egress
from app.security.redaction import redact_text

log = logging.getLogger(__name__)

__all__ = ["Candidate", "EgressOverrides", "ModelGateway"]


@dataclass(frozen=True)
class Candidate:
    model: ModelEntry
    provider: ResolvedProvider
    redact: bool
    egress_reason: str


class ModelGateway:
    def __init__(
        self,
        config: ConfigSource,
        *,
        http: httpx.AsyncClient | None = None,
        privacy_state: EgressOverrides | None = None,
        kill_switch: KillSwitchState | None = None,
        usage: UsageSink | None = None,
        retry: RetryPolicy | None = None,
        breaker_threshold: int = 3,
        breaker_open_s: float = 30.0,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        rand: Callable[[], float] = random.random,
        clock: Callable[[], float] = time.monotonic,
        adapters: Mapping[str, ProviderAdapter] | None = None,
    ) -> None:
        self._config = config
        self._owns_http = http is None
        self._http = http or httpx.AsyncClient()
        self._privacy = privacy_state
        self._kill_switch = kill_switch
        self.usage: UsageSink = usage or MemoryUsageSink()
        self._retry = retry or RetryPolicy()
        self._sleep, self._rand, self._clock = sleep, rand, clock
        self._breaker_threshold, self._breaker_open_s = breaker_threshold, breaker_open_s
        self._breakers: dict[str, CircuitBreaker] = {}
        self._adapters: Mapping[str, ProviderAdapter] = adapters or {
            "gemini": GeminiAdapter(self._http),
            "openai_compatible": OpenAICompatAdapter(self._http),
        }

    async def aclose(self) -> None:
        if self._owns_http:
            await self._http.aclose()

    def breaker(self, model_id: str) -> CircuitBreaker:
        b = self._breakers.get(model_id)
        if b is None:
            b = CircuitBreaker(
                failure_threshold=self._breaker_threshold,
                open_seconds=self._breaker_open_s,
                clock=self._clock,
            )
            self._breakers[model_id] = b
        return b

    # ---- selection -------------------------------------------------------------------------------

    async def _overrides(self) -> tuple[bool, frozenset[DataClass]]:
        if self._privacy is None:
            return False, frozenset()  # most restrictive: nothing granted to any external provider
        strict_public, granted = await self._privacy.egress_overrides()
        return strict_public, frozenset(granted) | DEFAULT_EXTERNAL_CLASSES

    async def candidates(
        self, task: TaskClass, data_classes: frozenset[DataClass], mode: PrivacyMode, capability: str
    ) -> list[Candidate]:
        """Permitted models for this request, in route order. `mode` is clamped to the server's mode."""
        cfg = self._config.current()
        mode = await clamp_mode(self._privacy, mode)
        killed = await kill_switch_on(self._kill_switch)
        strict_public, granted = await self._overrides()
        out: list[Candidate] = []
        reasons: dict[str, str] = {}
        denied_by_egress = False
        for mid in cfg.route(task):
            model = cfg.model(mid)
            if capability not in model.capabilities:
                reasons[mid] = f"lacks_{capability}"
                continue
            provider = self._config.resolve(model.provider)
            if not provider.enabled:
                reasons[mid] = f"provider_disabled:{provider.disabled_reason}"
                continue
            if blocked_by_kill_switch(killed, provider.entry.locality):
                reasons[mid] = KILL_SWITCH_REASON
                denied_by_egress = True
                continue
            decision = decide_egress(
                mode=mode,
                data_classes=data_classes,
                locality=provider.entry.locality,
                provider_allowed=provider.entry.allowed_data_classes & granted,
                strict_allow_public_external=strict_public,
            )
            if not decision.allowed:
                reasons[mid] = decision.reason
                denied_by_egress = True
                continue
            out.append(Candidate(model, provider, decision.redact, decision.reason))
        if not out:
            raise (EgressDenied if denied_by_egress else NoPermittedModel)(task, reasons)
        return out

    def _adapter_request(self, req: ChatRequest, c: Candidate) -> AdapterRequest:
        messages = redact_messages(req.messages) if c.redact else req.messages
        budget = input_budget(c.model.context_window, req.max_output_tokens, req.tools)
        return AdapterRequest(
            provider=c.provider,
            model=c.model,
            messages=trim_messages(messages, budget),
            tools=req.tools,
            response_schema=req.response_schema,
            max_output_tokens=req.max_output_tokens,
            temperature=req.temperature,
            timeout_s=req.timeout_s,
        )

    # ---- bookkeeping -----------------------------------------------------------------------------

    async def _record(
        self,
        req: ChatRequest,
        c: Candidate,
        t0: float,
        tokens: tuple[int, int] = (0, 0),
        err: str | None = None,
    ) -> None:
        tin, tout = tokens
        event = UsageRecord(
            provider=c.provider.entry.id,
            model=c.model.id,
            task=req.task.value,
            agent=req.agent.value if req.agent else None,
            turn_id=req.turn_id,
            input_tokens=tin,
            output_tokens=tout,
            latency_ms=int((self._clock() - t0) * 1000),
            cost_micro_usd=cost_micro_usd(c.model, tin, tout),
            error=err is not None,
            error_kind=err,
        )
        try:
            await self.usage.record(event)
        except Exception:  # usage accounting must never break a turn
            log.exception("usage event could not be recorded")

    def _on_failure(self, c: Candidate, err: ProviderError, attempt: int) -> float | None:
        """Update breaker state; return the delay before retrying this model, or None to fall back."""
        b = self.breaker(c.model.id)
        if err.kind == "rate_limited":
            ra = err.retry_after_s
            if (
                ra is not None
                and ra <= self._retry.max_retry_after_s
                and attempt + 1 < self._retry.max_attempts
            ):
                b.release()
                return ra
            b.cool_down(ra if ra is not None else self._retry.default_rate_limit_cooldown_s)
            return None
        if err.kind == "bad_request":
            b.release()
            return None
        b.record_failure()
        if err.kind == "auth" or not b.available() or attempt + 1 >= self._retry.max_attempts:
            return None
        return self._retry.backoff(attempt, self._rand())

    def _finish(self, req: ChatRequest, c: Candidate, resp: ChatResponse, latency_ms: int) -> ChatResponse:
        update: dict[str, Any] = {"latency_ms": latency_ms, "locality": c.provider.entry.locality}
        if req.response_schema is not None and not resp.tool_calls:
            try:
                update["parsed"] = json.loads(resp.text)
            except ValueError:
                raise ProviderError("bad_request", "invalid_structured_output") from None
        return resp.model_copy(update=update)

    # ---- public API ------------------------------------------------------------------------------

    async def permitted(
        self,
        task: TaskClass,
        data_classes: frozenset[DataClass],
        mode: PrivacyMode,
        capability: str = "chat",
    ) -> bool:
        """True when at least one configured model may receive this data for this task right now
        (privacy mode clamped, kill switch and egress policy applied). No network call."""
        try:
            return bool(await self.candidates(task, data_classes, mode, capability))
        except NoPermittedModel:
            return False

    async def turn_cost_usd(self, turn_id: str) -> Decimal:
        """Exact model cost recorded for one turn (USD, Decimal); 0 when nothing was recorded."""
        return await self.usage.turn_cost_usd(turn_id)

    async def chat(self, req: ChatRequest) -> ChatResponse:
        cands = await self.candidates(req.task, req.data_classes, req.privacy_mode, "chat")
        last: ProviderError | None = None
        for c in cands:
            if not self.breaker(c.model.id).allow():
                last = last or ProviderError("unavailable", f"circuit_open:{c.model.id}")
                continue
            try:
                areq = self._adapter_request(req, c)
            except ProviderError as exc:  # context overflow on this model: try a larger one
                self.breaker(c.model.id).release()
                last = exc
                continue
            adapter = self._adapters[c.provider.entry.kind]
            attempt = 0
            while True:
                t0 = self._clock()
                try:
                    resp = await asyncio.wait_for(adapter.chat(areq), timeout=req.timeout_s)
                    resp = self._finish(req, c, resp, int((self._clock() - t0) * 1000))
                except (ProviderError, TimeoutError) as exc:
                    err = exc if isinstance(exc, ProviderError) else ProviderError("timeout", "deadline")
                    await self._record(req, c, t0, err=err.kind)
                    if err.kind == "blocked":
                        self.breaker(c.model.id).release()
                        raise err from None
                    delay = self._on_failure(c, err, attempt)
                    last = err
                    if delay is None:
                        break
                    await self._sleep(delay)
                    attempt += 1
                    continue
                self.breaker(c.model.id).record_success()
                await self._record(req, c, t0, (resp.usage.input_tokens, resp.usage.output_tokens))
                return resp
        raise last or ProviderError("unavailable", "no candidate succeeded")

    async def stream(self, req: ChatRequest) -> AsyncIterator[ChatChunk]:
        """Stream a reply. Retry and fallback happen only before the first chunk is yielded."""
        cands = await self.candidates(req.task, req.data_classes, req.privacy_mode, "stream")
        last: ProviderError | None = None
        for c in cands:
            if not self.breaker(c.model.id).allow():
                last = last or ProviderError("unavailable", f"circuit_open:{c.model.id}")
                continue
            try:
                areq = self._adapter_request(req, c)
            except ProviderError as exc:
                self.breaker(c.model.id).release()
                last = exc
                continue
            attempt = 0
            while True:
                t0 = self._clock()
                agen = self._adapters[c.provider.entry.kind].stream(areq)
                try:
                    first = await asyncio.wait_for(anext(agen), timeout=req.timeout_s)
                except (ProviderError, TimeoutError, StopAsyncIteration) as exc:
                    err = (
                        exc if isinstance(exc, ProviderError) else ProviderError("timeout", "no first chunk")
                    )
                    await self._record(req, c, t0, err=err.kind)
                    if err.kind == "blocked":
                        self.breaker(c.model.id).release()
                        raise err from None
                    delay = self._on_failure(c, err, attempt)
                    last = err
                    if delay is None:
                        break
                    await self._sleep(delay)
                    attempt += 1
                    continue
                async for chunk in self._relay(req, c, t0, first, agen):
                    yield chunk
                return
        raise last or ProviderError("unavailable", "no candidate succeeded")

    async def _relay(
        self, req: ChatRequest, c: Candidate, t0: float, first: ChatChunk, agen: AsyncIterator[ChatChunk]
    ) -> AsyncIterator[ChatChunk]:
        chunk = first
        locality = c.provider.entry.locality
        try:
            while True:
                chunk = chunk.model_copy(update={"locality": locality})
                if chunk.done:
                    self.breaker(c.model.id).record_success()
                    u = chunk.usage
                    await self._record(req, c, t0, (u.input_tokens, u.output_tokens) if u else (0, 0))
                yield chunk
                if chunk.done:
                    return
                chunk = await asyncio.wait_for(anext(agen), timeout=req.timeout_s)
        except (ProviderError, TimeoutError, StopAsyncIteration) as exc:
            err = exc if isinstance(exc, ProviderError) else ProviderError("timeout", "stream stalled")
            self.breaker(c.model.id).record_failure()
            await self._record(req, c, t0, err=err.kind)
            raise err from None
        finally:
            self.breaker(c.model.id).release()  # consumer stopped early: never leave a trial pending
            aclose = getattr(agen, "aclose", None)
            if aclose is not None:
                await aclose()

    async def embed_with_model(
        self, texts: list[str], data_classes: frozenset[DataClass], privacy_mode: PrivacyMode
    ) -> EmbeddingResult:
        """Embed with the first permitted embedding model; `local-hash-v1` when none is permitted.

        Store `model` next to the vectors: vectors from different models are not comparable, so a
        failing cloud model raises instead of silently switching to the local embedder.
        """
        try:
            cands = await self.candidates(TaskClass.EMBEDDING, data_classes, privacy_mode, "embed")
        except NoPermittedModel:
            vecs = local_hash_embed(texts)
            return EmbeddingResult(model=LOCAL_HASH_MODEL_ID, dims=LOCAL_HASH_DIMS, vectors=_tup(vecs))
        req = ChatRequest(
            task=TaskClass.EMBEDDING, messages=(), data_classes=data_classes, privacy_mode=privacy_mode
        )
        last: ProviderError | None = None
        for c in cands:
            b = self.breaker(c.model.id)
            if not b.allow():
                continue
            payload = [redact_text(t).text for t in texts] if c.redact else list(texts)
            t0 = self._clock()
            try:
                vecs, tin = await self._adapters[c.provider.entry.kind].embed(
                    c.provider, c.model, payload, 30.0
                )
            except ProviderError as exc:
                await self._record(req, c, t0, err=exc.kind)
                self._on_failure(c, exc, self._retry.max_attempts)
                last = exc
                continue
            b.record_success()
            await self._record(req, c, t0, (tin, 0))
            dims = len(vecs[0]) if vecs else (c.model.dims or 0)
            return EmbeddingResult(model=c.model.id, dims=dims, vectors=_tup(vecs))
        raise last or ProviderError("unavailable", "embedding models unavailable")

    async def embed(
        self,
        texts: list[str],
        data_classes: frozenset[DataClass],
        privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE,
    ) -> list[list[float]]:
        result = await self.embed_with_model(texts, data_classes, privacy_mode)
        return [list(v) for v in result.vectors]

    async def route_info(
        self,
        privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE,
        data_classes: frozenset[DataClass] = frozenset({DataClass.PERSONAL}),
    ) -> list[ModelRouteInfo]:
        cfg = self._config.current()
        out: list[ModelRouteInfo] = []
        for task in TaskClass:
            ids = list(cfg.route(task))
            active: str | None = None
            locality: Locality | None = None
            reason = "no route configured" if not ids else ""
            try:
                cap = "embed" if task is TaskClass.EMBEDDING else "chat"
                if task in (TaskClass.REALTIME_VOICE, TaskClass.TTS):
                    cap = "realtime" if task is TaskClass.REALTIME_VOICE else "tts"
                usable = [
                    c
                    for c in await self.candidates(task, data_classes, privacy_mode, cap)
                    if self.breaker(c.model.id).available()
                ]
                if usable:
                    active, locality = usable[0].model.id, usable[0].provider.entry.locality
                else:
                    reason = "all permitted models are cooling down or circuit-open"
            except NoPermittedModel as exc:
                if task is TaskClass.EMBEDDING:
                    active, locality, reason = LOCAL_HASH_MODEL_ID, Locality.LOCAL, "local fallback embedder"
                elif ids:
                    reason = "; ".join(f"{k}: {v}" for k, v in exc.reasons.items())
            out.append(
                ModelRouteInfo(task=task, models=ids, active_model=active, locality=locality, reason=reason)
            )
        return out

    def health(self) -> dict[str, dict[str, Any]]:
        """Cheap, no network: configured state per provider and breaker state per model.
        It never claims live connectivity."""
        cfg = self._config.current()
        out: dict[str, dict[str, Any]] = {}
        for p in cfg.providers:
            rp = self._config.resolve(p.id)
            out[p.id] = {
                "enabled": rp.enabled,
                "reason": rp.disabled_reason,
                "locality": p.locality.value,
                "models": {
                    m.id: {
                        "breaker": self.breaker(m.id).state.value,
                        "cooling_down": self.breaker(m.id).cooling_down,
                    }
                    for m in cfg.models
                    if m.provider == p.id
                },
            }
        return out


def _tup(vecs: list[list[float]]) -> tuple[tuple[float, ...], ...]:
    return tuple(tuple(v) for v in vecs)
