"""Persistence of `VoiceSettings`."""

from __future__ import annotations

from app.core.clock import Clock
from app.db.session import SessionFactory
from app.schemas.data import VoiceSettings
from app.voice.models import VoiceSettingsRow

_KEY = "default"


class VoiceSettingsStore:
    def __init__(self, session_factory: SessionFactory, clock: Clock) -> None:
        self._sf = session_factory
        self._clock = clock

    async def get(self) -> VoiceSettings:
        async with self._sf() as session:
            row = await session.get(VoiceSettingsRow, _KEY)
        if row is None:
            return VoiceSettings()
        try:
            return VoiceSettings.model_validate(row.value)
        except ValueError:
            return VoiceSettings()  # an unreadable row falls back to defaults

    async def put(self, settings: VoiceSettings) -> VoiceSettings:
        value = settings.model_dump(mode="json")
        async with self._sf() as session:
            row = await session.get(VoiceSettingsRow, _KEY)
            if row is None:
                session.add(VoiceSettingsRow(key=_KEY, value=value, updated_at=self._clock.now()))
            else:
                row.value = value
                row.updated_at = self._clock.now()
            await session.commit()
        return settings
