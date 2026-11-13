"""`/v1/security`: state, privacy mode, kill switch, permissions, device revoke, audit.

Changes carry a `SignedProof` from the caller's approval key; `SecurityAdmin` verifies and audits.
These endpoints answer even while the kill switch is on.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.api.dependencies import CurrentDevice, Registry
from app.schemas.common import Page
from app.schemas.security import (
    AuditRecord,
    DeviceRevoke,
    KillSwitchUpdate,
    PermissionGrant,
    PermissionUpdate,
    PrivacyModeUpdate,
    SecurityState,
)

router = APIRouter(prefix="/security", tags=["security"])


@router.get("/state", response_model=SecurityState)
async def get_state(reg: Registry, device: CurrentDevice) -> SecurityState:
    state: SecurityState = await reg.service("security_admin").state(device)
    return state


@router.put("/privacy-mode", response_model=SecurityState)
async def set_privacy_mode(body: PrivacyModeUpdate, reg: Registry, device: CurrentDevice) -> SecurityState:
    state: SecurityState = await reg.service("security_admin").set_privacy_mode(device, body.mode, body.proof)
    return state


@router.post("/kill-switch")
async def set_kill_switch(body: KillSwitchUpdate, reg: Registry, device: CurrentDevice) -> dict[str, bool]:
    enabled: bool = await reg.service("security_admin").set_kill_switch(device, body.enabled, body.proof)
    return {"kill_switch": enabled}


@router.put("/permissions/{key}", response_model=PermissionGrant)
async def set_permission(
    key: str, body: PermissionUpdate, reg: Registry, device: CurrentDevice
) -> PermissionGrant:
    grant: PermissionGrant = await reg.service("security_admin").set_permission(
        device, key, body.granted, body.proof
    )
    return grant


@router.post("/devices/{device_id}/revoke", status_code=204)
async def revoke_device(device_id: str, body: DeviceRevoke, reg: Registry, device: CurrentDevice) -> None:
    await reg.service("security_admin").revoke_device(device, device_id, body.proof)


@router.get("/audit", response_model=Page[AuditRecord])
async def list_audit(
    reg: Registry,
    device: CurrentDevice,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> Page[AuditRecord]:
    page: Page[AuditRecord] = await reg.service("audit").list(cursor=cursor, limit=limit)
    return page
