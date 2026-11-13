"""Permission grants. Packages declare keys (`reg.add_permission`); the owner grants or withdraws them.

A key nobody declared is never granted. A tool's `permission` is static metadata: neither a model
nor another tool can change a grant, only a signed request from a paired device.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from sqlalchemy import select

from app.core.clock import Clock, SystemClock
from app.core.errors import PermissionUnknown
from app.db.session import SessionFactory
from app.schemas.security import PermissionGrant
from app.security.models import PermissionGrantRow

_KEY = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$")

#: Kernel grants that widen what external model providers may receive in cloud mode.
CLOUD_SENSITIVE = "cloud.sensitive"
CLOUD_FINANCIAL = "cloud.financial"
CLOUD_HEALTH = "cloud.health"


@dataclass(frozen=True)
class PermissionDecl:
    key: str
    title: str
    default: bool = False


class PermissionService:
    def __init__(self, session_factory: SessionFactory, clock: Clock | None = None) -> None:
        self._sf = session_factory
        self._clock = clock or SystemClock()
        self._declared: dict[str, PermissionDecl] = {}

    def declare(self, key: str, title: str, default: bool = False) -> PermissionDecl:
        """Register a grant key such as "finance.read". Re-declaring with the same values is a no-op;
        a conflicting re-declaration is a programming error."""
        if not _KEY.match(key):
            raise ValueError(f"permission key must look like 'package.verb': {key!r}")
        decl = PermissionDecl(key=key, title=title, default=bool(default))
        existing = self._declared.get(key)
        if existing is not None and existing != decl:
            raise ValueError(f"permission {key!r} is already declared with different values")
        self._declared[key] = decl
        return decl

    def declared(self) -> list[PermissionDecl]:
        return sorted(self._declared.values(), key=lambda decl: decl.key)

    def is_declared(self, key: str) -> bool:
        return key in self._declared

    async def is_granted(self, key: str) -> bool:
        decl = self._declared.get(key)
        if decl is None:
            return False
        async with self._sf() as session:
            row = await session.get(PermissionGrantRow, key)
        return decl.default if row is None else bool(row.granted)

    async def granted_keys(self) -> frozenset[str]:
        return frozenset(grant.key for grant in await self.list() if grant.granted)

    async def set(self, key: str, granted: bool, *, actor: str | None = None) -> PermissionGrant:
        decl = self._declared.get(key)
        if decl is None:
            raise PermissionUnknown()
        now = self._clock.now()
        async with self._sf() as session:
            row = await session.get(PermissionGrantRow, key)
            if row is None:
                session.add(PermissionGrantRow(key=key, granted=granted, updated_at=now, updated_by=actor))
            else:
                row.granted = granted
                row.updated_at = now
                row.updated_by = actor
            await session.commit()
        return PermissionGrant(key=key, title=decl.title, granted=granted, updated_at=now)

    async def list(self) -> list[PermissionGrant]:
        async with self._sf() as session:
            rows = {row.key: row for row in (await session.execute(select(PermissionGrantRow))).scalars()}
        grants: list[PermissionGrant] = []
        for decl in self.declared():
            row = rows.get(decl.key)
            grants.append(
                PermissionGrant(
                    key=decl.key,
                    title=decl.title,
                    granted=decl.default if row is None else bool(row.granted),
                    updated_at=None if row is None else row.updated_at,
                )
            )
        return grants
