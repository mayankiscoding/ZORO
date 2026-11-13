"""`/v1/memory`: the exact routes the Swift MemoryClient calls.

GET /memory (category, status, cursor, limit) -> Page · GET /memory/search?q= (category, limit) -> Page ·
POST /memory -> MemoryRecord · PATCH|DELETE /memory/{id} · GET|PUT /memory/settings ·
POST /memory/export (SignedProof) -> JSON document · POST /memory/categories/{category}/delete (SignedProof).
"""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Query, Response
from fastapi.responses import JSONResponse

from app.api.deps import CurrentDevice, Registry, require_device
from app.core.errors import BadRequest, Conflict
from app.core.types import MemoryCategory
from app.memory.access import ALL_BUT_SECRET
from app.memory.admin import MemoryAdmin
from app.memory.service import MemoryService
from app.schemas.common import Page
from app.schemas.data import (
    MemoryCreate,
    MemoryDeleteCategoryRequest,
    MemoryExportRequest,
    MemoryPatch,
    MemoryRecord,
    MemorySettings,
)

router = APIRouter(prefix="/memory", tags=["memory"], dependencies=[Depends(require_device)])

Status = Literal["active", "pending_review", "archived"]


def _service(reg: Registry) -> MemoryService:
    service: MemoryService = reg.service("memory")
    return service


def _admin(reg: Registry) -> MemoryAdmin:
    admin: MemoryAdmin = reg.service("memory_admin")
    return admin


@router.get("", response_model=Page[MemoryRecord])
async def list_memory(
    reg: Registry,
    category: MemoryCategory | None = None,
    status: Status | None = None,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> Page[MemoryRecord]:
    return await _service(reg).list(category=category, status=status, cursor=cursor, limit=limit)


@router.get("/search", response_model=Page[MemoryRecord])
async def search_memory(
    reg: Registry,
    q: Annotated[str, Query(min_length=1, max_length=300)],
    category: MemoryCategory | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
) -> Page[MemoryRecord]:
    """The owner's own view: pending and active records, also of categories switched off for recall."""
    hits = await _service(reg).search(
        q,
        category=category,
        limit=limit,
        statuses=("active", "pending_review"),
        allowed=ALL_BUT_SECRET,
        only_enabled=False,
        min_score=0.15,
    )
    return Page[MemoryRecord](items=[h.record for h in hits])


@router.get("/settings", response_model=MemorySettings)
async def get_settings(reg: Registry) -> MemorySettings:
    return await _service(reg).prefs.settings()


@router.put("/settings", response_model=MemorySettings)
async def put_settings(body: MemorySettings, reg: Registry, device: CurrentDevice) -> MemorySettings:
    return await _service(reg).update_settings(body, actor=device.device_id)


@router.post("/export")
async def export_memory(body: MemoryExportRequest, reg: Registry, device: CurrentDevice) -> JSONResponse:
    document = await _admin(reg).export(body.category, body.proof, device_id=device.device_id)
    return JSONResponse(
        content=document, headers={"Content-Disposition": 'attachment; filename="zoro-memory-export.json"'}
    )


@router.post("/categories/{category}/delete", status_code=204)
async def delete_category(
    category: MemoryCategory, body: MemoryDeleteCategoryRequest, reg: Registry, device: CurrentDevice
) -> Response:
    await _admin(reg).delete_category(category, body.proof, device_id=device.device_id)
    return Response(status_code=204)


@router.post("", response_model=MemoryRecord, status_code=201)
async def create_memory(
    body: MemoryCreate, reg: Registry, device: CurrentDevice, response: Response
) -> MemoryRecord:
    result = await _service(reg).add(
        category=body.category,
        text=body.text,
        sensitivity=body.sensitivity,
        source="user",
        confidence=1.0,
        status="active",
    )
    if result.outcome == "skipped_disabled":
        raise Conflict(
            f"Memory for {body.category.value} is switched off. Turn it on in Memory settings first.",
            code="memory_category_disabled",
        )
    if result.outcome == "rejected_secret" or result.record is None:
        raise BadRequest(
            "Passwords, PINs, OTPs and keys are never stored in memory.", code="memory_secret_refused"
        )
    if result.outcome != "created":
        response.status_code = 200  # an existing record was returned (merged or kept)
    return result.record


@router.patch("/{memory_id}", response_model=MemoryRecord)
async def patch_memory(
    memory_id: str, body: MemoryPatch, reg: Registry, device: CurrentDevice
) -> MemoryRecord:
    return await _service(reg).patch(memory_id, body, actor=device.device_id)


@router.delete("/{memory_id}", status_code=204)
async def delete_memory(memory_id: str, reg: Registry, device: CurrentDevice) -> Response:
    service = _service(reg)
    await service.get(memory_id)  # 404 memory_not_found when unknown
    await service.delete(memory_id, actor=device.device_id)
    return Response(status_code=204)
