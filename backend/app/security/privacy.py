"""Privacy state: the server-wide privacy mode and what widens model egress.

Registered as service ``privacy_state``. The model gateway reads it before every request and
passes the values to `decide_egress`; nothing here is settable by a model.
"""

from __future__ import annotations

from collections.abc import Callable

from app.core.types import DataClass, PrivacyMode
from app.security.permissions import CLOUD_FINANCIAL, CLOUD_HEALTH, CLOUD_SENSITIVE, PermissionService
from app.security.policy import PolicyConfig
from app.security.state import PRIVACY_MODE_KEY, KillSwitch, SecuritySettingsStore

_GRANT_CLASSES: dict[str, DataClass] = {
    CLOUD_SENSITIVE: DataClass.SENSITIVE,
    CLOUD_FINANCIAL: DataClass.FINANCIAL,
    CLOUD_HEALTH: DataClass.HEALTH,
}


def stricter_mode(server: PrivacyMode, requested: PrivacyMode | None) -> PrivacyMode:
    """A client may ask for a stricter mode per turn, never a looser one."""
    if requested is PrivacyMode.STRICT_PRIVATE or server is PrivacyMode.STRICT_PRIVATE:
        return PrivacyMode.STRICT_PRIVATE
    return server


class PrivacyStateService:
    def __init__(
        self,
        store: SecuritySettingsStore,
        permissions: PermissionService,
        *,
        default_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE,
        config: Callable[[], PolicyConfig] | None = None,
        kill_switch: KillSwitch | None = None,
    ) -> None:
        self._store = store
        self._permissions = permissions
        self._default = default_mode
        self._config = config or PolicyConfig
        self._kill_switch = kill_switch

    async def _killed(self) -> bool:
        return self._kill_switch is not None and await self._kill_switch.is_on()

    async def get_mode(self) -> PrivacyMode:
        """The mode in force right now. While the kill switch is on this is always strict private,
        whatever the owner chose (see `stored_mode`)."""
        if await self._killed():
            return PrivacyMode.STRICT_PRIVATE
        return await self.stored_mode()

    async def stored_mode(self) -> PrivacyMode:
        """The mode the owner chose (or the configured default)."""
        value = await self._store.get(PRIVACY_MODE_KEY, None)
        if value is None:
            return self._default
        try:
            return PrivacyMode(value)
        except ValueError:
            return PrivacyMode.STRICT_PRIVATE  # an unreadable setting never loosens privacy

    async def set_mode(self, mode: PrivacyMode, *, actor: str | None = None) -> PrivacyMode:
        await self._store.set(PRIVACY_MODE_KEY, PrivacyMode(mode).value, actor=actor)
        return PrivacyMode(mode)

    async def effective_mode(self, requested: PrivacyMode | None) -> PrivacyMode:
        return stricter_mode(await self.get_mode(), requested)

    async def egress_overrides(self) -> tuple[bool, frozenset[DataClass]]:
        """`(strict_allow_public_external, extra data classes granted to external providers)`.

        The extra classes come from the owner's `cloud.sensitive`, `cloud.financial` and
        `cloud.health` grants; add them to a provider's configured classes (never `SECRET`).
        While the kill switch is on nothing is widened: `(False, frozenset())`.
        """
        if await self._killed():
            return False, frozenset()
        extra = frozenset(
            [
                data_class
                for key, data_class in _GRANT_CLASSES.items()
                if await self._permissions.is_granted(key)
            ]
        )
        return self._config().toggles.strict_allow_public_external, extra
