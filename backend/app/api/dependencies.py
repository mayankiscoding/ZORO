"""FastAPI dependencies shared by every router (HTTP and WebSocket)."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Annotated, cast

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.requests import HTTPConnection

from app.core.errors import KillSwitchActive, Unauthorized
from app.plugins import PluginRegistry
from app.security.sessions import AuthedDevice


def get_registry(conn: HTTPConnection) -> PluginRegistry:
    return cast(PluginRegistry, conn.app.state.registry)


async def get_session(conn: HTTPConnection) -> AsyncIterator[AsyncSession]:
    """One `AsyncSession` per request: committed when the handler returns, rolled back when it
    raises."""
    factory = get_registry(conn).service("session_factory")
    async with factory() as session:
        try:
            yield session
            await session.commit()
        except BaseException:
            await session.rollback()
            raise


def bearer_token(conn: HTTPConnection) -> str:
    header = conn.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise Unauthorized("Send the session token as 'Authorization: Bearer <token>'.")
    return token.strip()


async def require_device(conn: HTTPConnection) -> AuthedDevice:
    """The paired, signed-in device behind this request. Raises 401 (`token_invalid`,
    `device_revoked`, `unauthorized`)."""
    registry = get_registry(conn)
    device = await registry.service("sessions").authenticate(bearer_token(conn))
    await registry.service("devices").touch(device.device_id)
    return cast(AuthedDevice, device)


async def block_when_killed(conn: HTTPConnection) -> None:
    """Applied to everything except auth, security and health: the kill switch stops it all."""
    if await get_registry(conn).service("kill_switch").is_on():
        raise KillSwitchActive()


Registry = Annotated[PluginRegistry, Depends(get_registry)]
DbSession = Annotated[AsyncSession, Depends(get_session)]
CurrentDevice = Annotated[AuthedDevice, Depends(require_device)]
