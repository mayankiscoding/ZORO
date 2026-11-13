"""Per-category memory settings (enabled, retention) and the conversation retention setting."""

from __future__ import annotations

from sqlalchemy import select

from app.core.errors import ValidationFailed
from app.core.types import MemoryCategory
from app.db.session import SessionFactory
from app.memory.models import MemoryCategorySettingRow, MemoryMetaRow
from app.schemas.data import MemoryCategorySetting, MemorySettings

_CONVERSATION_KEY = "conversation_retention_days"


class MemoryPrefs:
    def __init__(self, session_factory: SessionFactory, default_conversation_days: int) -> None:
        self._sf = session_factory
        self._default_conversation_days = default_conversation_days

    async def _rows(self) -> dict[str, MemoryCategorySettingRow]:
        async with self._sf() as session:
            rows = (await session.execute(select(MemoryCategorySettingRow))).scalars().all()
        return {row.category: row for row in rows}

    async def get(self, category: MemoryCategory) -> MemoryCategorySetting:
        row = (await self._rows()).get(category.value)
        if row is None:
            return MemoryCategorySetting(category=category, enabled=True, retention_days=None)
        return MemoryCategorySetting(
            category=category, enabled=row.enabled, retention_days=row.retention_days
        )

    async def is_enabled(self, category: MemoryCategory) -> bool:
        return (await self.get(category)).enabled

    async def enabled_categories(self) -> list[MemoryCategory]:
        rows = await self._rows()
        return [c for c in MemoryCategory if rows.get(c.value) is None or rows[c.value].enabled]

    async def conversation_retention_days(self) -> int:
        async with self._sf() as session:
            row = await session.get(MemoryMetaRow, _CONVERSATION_KEY)
        return int(row.value) if row is not None else self._default_conversation_days

    async def settings(self) -> MemorySettings:
        rows = await self._rows()
        categories = [
            MemoryCategorySetting(
                category=c,
                enabled=True if c.value not in rows else rows[c.value].enabled,
                retention_days=None if c.value not in rows else rows[c.value].retention_days,
            )
            for c in MemoryCategory
        ]
        return MemorySettings(
            categories=categories, conversation_retention_days=await self.conversation_retention_days()
        )

    async def update(self, new: MemorySettings) -> dict[MemoryCategory, int | None]:
        """Apply the given categories (others stay). Returns categories whose retention changed."""
        if new.conversation_retention_days < 0:
            raise ValidationFailed("Conversation retention cannot be negative.")
        for item in new.categories:
            if item.retention_days is not None and item.retention_days < 1:
                raise ValidationFailed("Retention must be at least one day, or empty to keep until deleted.")
        rows = await self._rows()
        before: dict[MemoryCategory, int | None] = {
            c: (rows[c.value].retention_days if c.value in rows else None) for c in MemoryCategory
        }
        changed: dict[MemoryCategory, int | None] = {}
        async with self._sf() as session:
            for item in new.categories:
                row = await session.get(MemoryCategorySettingRow, item.category.value)
                if row is None:
                    session.add(
                        MemoryCategorySettingRow(
                            category=item.category.value,
                            enabled=item.enabled,
                            retention_days=item.retention_days,
                        )
                    )
                else:
                    row.enabled = item.enabled
                    row.retention_days = item.retention_days
                if before[item.category] != item.retention_days:
                    changed[item.category] = item.retention_days
            meta = await session.get(MemoryMetaRow, _CONVERSATION_KEY)
            value = str(new.conversation_retention_days)
            if meta is None:
                session.add(MemoryMetaRow(key=_CONVERSATION_KEY, value=value))
            else:
                meta.value = value
            await session.commit()
        return changed
