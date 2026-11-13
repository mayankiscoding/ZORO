"""Persistent security switches: a small key/value store and the kill switch built on it."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select, update

from app.core.clock import Clock, SystemClock
from app.db.session import SessionFactory
from app.security.models import DeviceSession, SecuritySetting

KILL_SWITCH_KEY = "kill_switch"
PRIVACY_MODE_KEY = "privacy_mode"


class SecuritySettingsStore:
    def __init__(self, session_factory: SessionFactory, clock: Clock | None = None) -> None:
        self._sf = session_factory
        self._clock = clock or SystemClock()

    async def get(self, key: str, default: Any = None) -> Any:
        async with self._sf() as session:
            row = await session.get(SecuritySetting, key)
            return default if row is None else row.value

    async def set(self, key: str, value: Any, *, actor: str | None = None) -> None:
        async with self._sf() as session:
            row = await session.get(SecuritySetting, key)
            if row is None:
                session.add(
                    SecuritySetting(key=key, value=value, updated_at=self._clock.now(), updated_by=actor)
                )
            else:
                row.value = value
                row.updated_at = self._clock.now()
                row.updated_by = actor
            await session.commit()


class KillSwitch:
    """One flag. While it is on, no tool runs, no external inference happens, and only the auth
    and security endpoints answer. Turning it on also ends every session."""

    def __init__(self, session_factory: SessionFactory, clock: Clock | None = None) -> None:
        self._sf = session_factory
        self._clock = clock or SystemClock()
        self._store = SecuritySettingsStore(session_factory, self._clock)

    async def is_on(self) -> bool:
        return bool(await self._store.get(KILL_SWITCH_KEY, False))

    async def set(self, enabled: bool, *, actor: str | None = None) -> bool:
        """Persist the flag. Returns True when the value changed."""
        was_on = await self.is_on()
        await self._store.set(KILL_SWITCH_KEY, bool(enabled), actor=actor)
        if enabled:
            async with self._sf() as session:
                await session.execute(
                    update(DeviceSession)
                    .where(DeviceSession.revoked_at.is_(None))
                    .values(revoked_at=self._clock.now())
                )
                await session.commit()
        return was_on != bool(enabled)


async def active_session_count(session_factory: SessionFactory) -> int:
    async with session_factory() as session:
        rows = await session.execute(select(DeviceSession.id).where(DeviceSession.revoked_at.is_(None)))
        return len(rows.all())
