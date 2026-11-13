"""Usage recording and cost maths. Cost = tokens x price-per-1M, exact in Decimal, stored as micro-USD."""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from decimal import ROUND_HALF_UP, Decimal
from typing import Any, Literal, Protocol

from sqlalchemy import Integer, case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.base import utcnow
from app.providers.config import ModelEntry
from app.providers.models import UsageEvent
from app.schemas.security import CostRow, CostSummary

log = logging.getLogger(__name__)

GroupBy = Literal["provider", "model", "task", "agent", "day"]
SessionFactory = Callable[[], Any]  # async_sessionmaker[AsyncSession] or compatible
_MICRO = Decimal(1_000_000)


def cost_micro_usd(model: ModelEntry, input_tokens: int, output_tokens: int) -> int:
    """Price is USD per 1M tokens, so micro-USD = tokens x price exactly; round half up to integer."""
    exact = Decimal(input_tokens) * model.price_in + Decimal(output_tokens) * model.price_out
    return int(exact.quantize(Decimal(1), rounding=ROUND_HALF_UP))


def micro_to_usd(micro: int) -> Decimal:
    return Decimal(micro) / _MICRO


@dataclass(frozen=True)
class UsageRecord:
    provider: str
    model: str
    task: str
    agent: str | None = None
    turn_id: str | None = None
    input_tokens: int = 0
    output_tokens: int = 0
    audio_seconds: float = 0.0
    latency_ms: int = 0
    cost_micro_usd: int = 0
    error: bool = False
    error_kind: str | None = None
    ts: datetime = field(default_factory=utcnow)


class UsageSink(Protocol):
    async def record(self, event: UsageRecord) -> None: ...

    async def turn_cost_usd(self, turn_id: str) -> Decimal: ...


class MemoryUsageSink:
    def __init__(self) -> None:
        self.events: list[UsageRecord] = []

    async def record(self, event: UsageRecord) -> None:
        self.events.append(event)

    async def turn_cost_usd(self, turn_id: str) -> Decimal:
        return micro_to_usd(sum(e.cost_micro_usd for e in self.events if e.turn_id == turn_id))


class DbUsageSink:
    """Writes one `UsageEvent` row per record in its own short transaction."""

    def __init__(self, session_factory: SessionFactory) -> None:
        self._sf = session_factory

    async def record(self, event: UsageRecord) -> None:
        session: AsyncSession
        async with self._sf() as session, session.begin():
            session.add(
                UsageEvent(
                    ts=event.ts,
                    provider=event.provider,
                    model=event.model,
                    task=event.task,
                    agent=event.agent,
                    turn_id=event.turn_id,
                    input_tokens=event.input_tokens,
                    output_tokens=event.output_tokens,
                    audio_seconds=event.audio_seconds,
                    latency_ms=event.latency_ms,
                    cost_micro_usd=event.cost_micro_usd,
                    error=event.error,
                    error_kind=event.error_kind,
                )
            )

    async def turn_cost_usd(self, turn_id: str) -> Decimal:
        return await turn_cost_usd(self._sf, turn_id)


async def turn_cost_usd(session_factory: SessionFactory, turn_id: str) -> Decimal:
    """Sum of the recorded model cost of one turn, exact (micro-USD summed in SQL, then Decimal)."""
    session: AsyncSession
    async with session_factory() as session:
        stmt = select(func.coalesce(func.sum(UsageEvent.cost_micro_usd), 0)).where(
            UsageEvent.turn_id == turn_id
        )
        micro = (await session.execute(stmt)).scalar_one()
    return micro_to_usd(int(micro))


def _key_column(group_by: GroupBy, dialect: str) -> Any:
    if group_by == "day":
        if dialect == "sqlite":
            return func.strftime("%Y-%m-%d", UsageEvent.ts)
        return func.to_char(func.timezone("UTC", UsageEvent.ts), "YYYY-MM-DD")
    if group_by == "agent":
        return func.coalesce(UsageEvent.agent, "none")
    return {"provider": UsageEvent.provider, "model": UsageEvent.model, "task": UsageEvent.task}[group_by]


async def cost_summary(
    session_factory: SessionFactory,
    group_by: GroupBy,
    *,
    since: datetime | None = None,
    until: datetime | None = None,
) -> CostSummary:
    session: AsyncSession
    async with session_factory() as session:
        key = _key_column(group_by, session.get_bind().dialect.name).label("key")
        stmt = (
            select(
                key,
                func.count().label("requests"),
                func.coalesce(func.sum(UsageEvent.input_tokens), 0),
                func.coalesce(func.sum(UsageEvent.output_tokens), 0),
                func.coalesce(func.sum(UsageEvent.audio_seconds), 0.0),
                func.coalesce(func.avg(UsageEvent.latency_ms), 0.0),
                func.coalesce(func.sum(case((UsageEvent.error, 1), else_=0).cast(Integer)), 0),
                func.coalesce(func.sum(UsageEvent.cost_micro_usd), 0),
            )
            .group_by(key)
            .order_by(key)
        )
        if since is not None:
            stmt = stmt.where(UsageEvent.ts >= since)
        if until is not None:
            stmt = stmt.where(UsageEvent.ts < until)
        rows = (await session.execute(stmt)).all()
    items: list[CostRow] = []
    total = 0
    for k, n, tin, tout, audio, lat, errors, micro in rows:
        total += int(micro)
        items.append(
            CostRow(
                key=str(k),
                requests=int(n),
                input_tokens=int(tin),
                output_tokens=int(tout),
                audio_seconds=float(audio),
                avg_latency_ms=round(float(lat), 1),
                error_rate=round(int(errors) / int(n), 4) if n else 0.0,
                cost_usd=micro_to_usd(int(micro)),
            )
        )
    return CostSummary(group_by=group_by, total_cost_usd=micro_to_usd(total), items=items)
