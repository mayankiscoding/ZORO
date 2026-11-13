"""The shared music session context: provider, active device, last query and track."""

from __future__ import annotations

from datetime import datetime

from app.core.clock import Clock
from app.db.session import SessionFactory
from app.music.models import MusicSessionRow
from app.music.schemas import MusicSession, MusicSessionUpdate, MusicTrack, SessionDevice

_KEY = "default"


class MusicSessionService:
    def __init__(self, session_factory: SessionFactory, clock: Clock) -> None:
        self._sf = session_factory
        self._clock = clock

    async def get(self) -> MusicSession:
        async with self._sf() as session:
            row = await session.get(MusicSessionRow, _KEY)
        if row is None:
            return MusicSession()
        try:
            return MusicSession.model_validate({**row.value, "updated_at": row.updated_at})
        except ValueError:
            return MusicSession()

    async def _save(self, value: MusicSession, actor: str | None) -> MusicSession:
        now: datetime = self._clock.now()
        stored = value.model_copy(update={"updated_at": now, "updated_by": actor})
        payload = stored.model_dump(mode="json", exclude={"updated_at"})
        async with self._sf() as session:
            row = await session.get(MusicSessionRow, _KEY)
            if row is None:
                session.add(MusicSessionRow(key=_KEY, value=payload, updated_at=now))
            else:
                row.value = payload
                row.updated_at = now
            await session.commit()
        return stored

    async def update(self, change: MusicSessionUpdate, *, actor: str | None = None) -> MusicSession:
        current = await self.get()
        fields = change.model_dump(exclude_unset=True)
        merged = current.model_copy(update={k: getattr(change, k) for k in fields})
        return await self._save(merged, actor)

    async def played(
        self,
        *,
        provider: str,
        device: SessionDevice | None,
        query: str | None,
        track: MusicTrack | None,
        actor: str | None = None,
    ) -> MusicSession:
        """Record what just happened. A control that names no new device keeps the active one."""
        current = await self.get()
        update: dict[str, object] = {"provider": provider if provider in ("spotify", "apple_music") else None}
        if device is not None:
            update["active_device"] = device
        if query:
            update["last_query"] = query
        if track is not None:
            update["last_track"] = track
        return await self._save(current.model_copy(update=update), actor)
