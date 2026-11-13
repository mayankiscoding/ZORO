"""Which data classes may be handed to the caller of a recall or search."""

from __future__ import annotations

from typing import Any

from app.core.types import DataClass, PrivacyMode

ALL_BUT_SECRET: frozenset[DataClass] = frozenset(
    {DataClass.PUBLIC, DataClass.PERSONAL, DataClass.SENSITIVE, DataClass.FINANCIAL, DataClass.HEALTH}
)
CLOUD_DEFAULT: frozenset[DataClass] = frozenset({DataClass.PUBLIC, DataClass.PERSONAL})


async def allowed_classes(privacy_state: Any | None, mode: PrivacyMode) -> frozenset[DataClass]:
    """Strict private: everything except secrets (nothing leaves the machine). Cloud mode: public and
    personal plus the classes the owner granted to cloud models; with no privacy service, only the
    defaults. `secret` is never returned."""
    if mode is PrivacyMode.STRICT_PRIVATE:
        return ALL_BUT_SECRET
    if privacy_state is None:
        return CLOUD_DEFAULT
    _, granted = await privacy_state.egress_overrides()
    return (CLOUD_DEFAULT | frozenset(granted)) - {DataClass.SECRET}
