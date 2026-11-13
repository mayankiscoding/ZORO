"""HTTP surface of the orchestrator. Turn endpoints answer with Server-Sent Events:
``event: <type>`` + ``data: <json of the event model>`` + a blank line."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Annotated, Any

from fastapi import APIRouter, Query, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app.api.deps import CurrentDevice
from app.core.types import TurnStatus
from app.orchestrator.service import TurnService
from app.orchestrator.store import ConversationStore
from app.schemas.common import Page
from app.schemas.data import ConversationSummary, Message
from app.schemas.turns import ResumeRequest, TurnRequest

SSE_HEADERS = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}


class TurnStatusResponse(BaseModel):
    turn_id: str
    status: TurnStatus


def sse_frame(event: BaseModel) -> bytes:
    """One SSE frame. The JSON has no raw newlines, so a single `data:` line carries it."""
    name = getattr(event, "type", "message")
    return f"event: {name}\ndata: {event.model_dump_json()}\n\n".encode()


async def sse(events: AsyncIterator[Any]) -> AsyncIterator[bytes]:
    async for event in events:
        yield sse_frame(event)


def _stream(events: AsyncIterator[Any]) -> StreamingResponse:
    return StreamingResponse(sse(events), media_type="text/event-stream", headers=SSE_HEADERS)


def build_router(service: TurnService, store: ConversationStore) -> APIRouter:
    router = APIRouter(tags=["turns"])

    @router.post("/turns", response_class=StreamingResponse)
    async def start_turn(body: TurnRequest, device: CurrentDevice) -> StreamingResponse:
        return _stream(await service.start(body, device))

    @router.post("/turns/{turn_id}/resume", response_class=StreamingResponse)
    async def resume_turn(turn_id: str, body: ResumeRequest, device: CurrentDevice) -> StreamingResponse:
        return _stream(await service.resume(turn_id, body, device))

    @router.post("/turns/{turn_id}/cancel")
    async def cancel_turn(turn_id: str, device: CurrentDevice) -> TurnStatusResponse:
        return TurnStatusResponse(turn_id=turn_id, status=await service.cancel(turn_id))

    @router.get("/conversations")
    async def list_conversations(
        device: CurrentDevice,
        cursor: str | None = None,
        limit: Annotated[int, Query(ge=1, le=100)] = 20,
    ) -> Page[ConversationSummary]:
        return await store.list_conversations(cursor=cursor, limit=limit)

    @router.get("/conversations/{conversation_id}/messages")
    async def list_messages(
        conversation_id: str,
        device: CurrentDevice,
        cursor: str | None = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ) -> Page[Message]:
        return await store.list_messages(conversation_id, cursor=cursor, limit=limit)

    @router.delete("/conversations/{conversation_id}", status_code=204)
    async def delete_conversation(conversation_id: str, device: CurrentDevice) -> Response:
        await service.delete_conversation(conversation_id)
        return Response(status_code=204)

    return router
