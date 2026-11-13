"""`/v1/automations` routes. Thin: rules live in `RoutineService` and `RoutineRunner`."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query

from app.automation.runner import RoutineRunner
from app.automation.schemas import EnableBody, RoutineIn, RoutineOut, RunBody, RunOut
from app.automation.service import RoutineService
from app.core.errors import BadRequest, Forbidden
from app.schemas.turns import ResumeRequest

READ, RUN, MANAGE = "automation.read", "automation.run", "automation.manage"


def build_router(
    reg: Any, service: RoutineService, runner: RoutineRunner, require_device: Callable[..., Awaitable[Any]]
) -> APIRouter:
    router = APIRouter(prefix="/automations", tags=["automations"], dependencies=[Depends(require_device)])

    def grant(key: str) -> Callable[[], Awaitable[None]]:
        async def check() -> None:
            if not await reg.service("permissions").is_granted(key):
                raise Forbidden(
                    f"Allow '{key}' in Security and privacy first.", code=f"permission_not_granted:{key}"
                )

        return check

    can_read, can_run, can_manage = (Depends(grant(k)) for k in (READ, RUN, MANAGE))
    auth = Depends(require_device)  # the signed-in device, for the routes that record or use it

    @router.get("", response_model=list[RoutineOut], dependencies=[can_read])
    async def list_routines(include_disabled: bool = True) -> list[RoutineOut]:
        return await service.list_all(include_disabled=include_disabled)

    @router.post("", response_model=RoutineOut, dependencies=[can_manage])
    async def save_routine(body: RoutineIn, who: Any = auth) -> RoutineOut:
        return await service.save(body, created_by=who.device_id)

    # Run routes come before "/{ref}" so "runs" is never read as a routine name.
    @router.get("/runs/{run_id}", response_model=RunOut, dependencies=[can_read])
    async def get_run(run_id: str) -> RunOut:
        return await service.get_run(run_id)

    @router.post("/runs/{run_id}/resume", response_model=RunOut, dependencies=[can_run])
    async def resume_run(run_id: str, body: ResumeRequest, who: Any = auth) -> RunOut:
        if (body.approval is None) == (body.device_result is None):
            raise BadRequest("Send exactly one of 'approval' or 'device_result'.", code="resume_body_invalid")
        return await runner.resume(
            run_id, device_id=who.device_id, approval=body.approval, device_result=body.device_result
        )

    @router.post("/runs/{run_id}/cancel", response_model=RunOut, dependencies=[can_run])
    async def cancel_run(run_id: str) -> RunOut:
        return await runner.cancel(run_id)

    @router.get("/{ref}", response_model=RoutineOut, dependencies=[can_read])
    async def get_routine(ref: str) -> RoutineOut:
        return await service.get(ref)

    @router.patch("/{ref}", response_model=RoutineOut, dependencies=[can_manage])
    async def enable_routine(ref: str, body: EnableBody) -> RoutineOut:
        return await service.set_enabled(ref, body.enabled)

    @router.delete("/{ref}", status_code=204, dependencies=[can_manage])
    async def delete_routine(ref: str) -> None:
        await service.delete(ref)

    @router.post("/{ref}/run", response_model=RunOut, dependencies=[can_run])
    async def run_routine(ref: str, who: Any = auth, body: RunBody | None = None) -> RunOut:
        return await runner.start(
            ref, params=(body.params if body else {}), trigger_kind="manual", device_id=who.device_id
        )

    @router.get("/{ref}/runs", response_model=list[RunOut], dependencies=[can_read])
    async def runs(ref: str, limit: Annotated[int, Query(ge=1, le=50)] = 20) -> list[RunOut]:
        return await service.runs(ref, limit)

    return router
