"""May a model see this data right now? Asked before any model call so a turn that must stay
deterministic makes zero gateway calls. The gateway still enforces egress on every request."""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from app.core.types import DataClass, Locality, PrivacyMode, TaskClass
from app.providers.types import NoPermittedModel
from app.security.egress import DEFAULT_EXTERNAL_CLASSES, decide_egress


async def _overrides(reg: Any) -> tuple[bool, frozenset[DataClass]]:
    if not reg.has_service("privacy_state"):
        return False, frozenset()
    strict_public, granted = await reg.service("privacy_state").egress_overrides()
    return bool(strict_public), frozenset(granted)


async def external_allowed(reg: Any, mode: PrivacyMode, data_classes: Iterable[DataClass]) -> bool:
    """Would `decide_egress` let these data classes reach an external provider in `mode`?
    False while the kill switch is on."""
    if reg.has_service("kill_switch") and await reg.service("kill_switch").is_on():
        return False
    strict_public, granted = await _overrides(reg)
    decision = decide_egress(
        mode=mode,
        data_classes=data_classes,
        locality=Locality.EXTERNAL,
        provider_allowed=DEFAULT_EXTERNAL_CLASSES | granted,
        strict_allow_public_external=strict_public,
    )
    return decision.allowed


async def model_permitted(
    reg: Any, task: TaskClass, data_classes: Iterable[DataClass], mode: PrivacyMode
) -> bool:
    """True when the gateway has at least one model that may receive `data_classes` for `task`.

    A gateway that can list candidates (the real one) is asked directly, so a local model keeps
    working in strict private mode. One that cannot is treated as an external provider.
    """
    if not reg.has_service("gateway"):
        return False
    if reg.has_service("kill_switch") and await reg.service("kill_switch").is_on():
        return False
    classes = frozenset(data_classes) or frozenset({DataClass.PERSONAL})
    if DataClass.SECRET in classes:
        return False
    gateway = reg.service("gateway")
    candidates = getattr(gateway, "candidates", None)
    if candidates is None:
        return await external_allowed(reg, mode, classes)
    try:
        return bool(await candidates(task, classes, mode, "chat"))
    except NoPermittedModel:
        return False
