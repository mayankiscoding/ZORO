"""Server-side privacy guard of the model gateway.

The request's privacy mode is a *request*: the gateway clamps it to the stricter of the request and
the server's privacy state, so a caller can tighten privacy for one turn but never loosen it. While
the kill switch is on no external provider is called at all (local models keep working).
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from app.core.types import DataClass, Locality, PrivacyMode

KILL_SWITCH_REASON = "kill_switch_on"


class EgressOverrides(Protocol):
    async def egress_overrides(self) -> tuple[bool, frozenset[DataClass]]:
        """(strict_allow_public_external, data classes the owner granted to external providers)."""
        ...


@runtime_checkable
class ServerPrivacyMode(Protocol):
    async def get_mode(self) -> PrivacyMode:
        """The privacy mode in force on the server right now."""
        ...


class KillSwitchState(Protocol):
    async def is_on(self) -> bool: ...


def stricter(a: PrivacyMode, b: PrivacyMode) -> PrivacyMode:
    """Strict private wins over cloud intelligence."""
    if PrivacyMode.STRICT_PRIVATE in (a, b):
        return PrivacyMode.STRICT_PRIVATE
    return a


async def clamp_mode(privacy_state: EgressOverrides | None, requested: PrivacyMode) -> PrivacyMode:
    """The mode a request actually runs under.

    With no privacy state wired (unit tests, scripts) the request's own mode is used; the egress
    overrides are then the most restrictive ones, so external providers still receive nothing.
    """
    if isinstance(privacy_state, ServerPrivacyMode):
        return stricter(await privacy_state.get_mode(), requested)
    return requested


async def kill_switch_on(kill_switch: KillSwitchState | None) -> bool:
    return kill_switch is not None and await kill_switch.is_on()


def blocked_by_kill_switch(killed: bool, locality: Locality) -> bool:
    """External inference stops while the kill switch is on; private localities are unaffected."""
    return killed and locality is Locality.EXTERNAL
