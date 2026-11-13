"""Model-egress decision: may this data go to this model provider?

Pure function, no I/O, so it can be tested exhaustively and called from every provider adapter.
The model gateway MUST call `decide_egress` before every request and refuse when it is not allowed.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass

from app.core.types import DataClass, Locality, PrivacyMode

#: What an external provider may receive in cloud mode unless the user widened it in config/policy.yaml.
DEFAULT_EXTERNAL_CLASSES: frozenset[DataClass] = frozenset({DataClass.PUBLIC, DataClass.PERSONAL})

_PRIVATE_LOCALITIES = frozenset({Locality.ON_DEVICE, Locality.LOCAL, Locality.PRIVATE_NETWORK})


@dataclass(frozen=True)
class EgressDecision:
    allowed: bool
    redact: bool
    reason: str


def decide_egress(
    *,
    mode: PrivacyMode,
    data_classes: Iterable[DataClass],
    locality: Locality,
    provider_allowed: frozenset[DataClass] = DEFAULT_EXTERNAL_CLASSES,
    strict_allow_public_external: bool = False,
) -> EgressDecision:
    """Decide whether content with `data_classes` may be sent to a provider at `locality`.

    - Unknown classification (empty set) is treated as PERSONAL, never as PUBLIC.
    - SECRET content is never sent to any model, local or not.
    - Private localities may receive everything else.
    - External providers: strict private mode refuses everything, except PUBLIC-only content when
      the user explicitly enabled `strict_allow_public_external`. Cloud mode allows only the
      classes granted to that provider; anything above PUBLIC is redacted before sending.
    """
    classes = frozenset(data_classes) or frozenset({DataClass.PERSONAL})

    if DataClass.SECRET in classes:
        return EgressDecision(False, False, "secret_never_leaves")

    if locality in _PRIVATE_LOCALITIES:
        return EgressDecision(True, False, "private_locality")

    if mode is PrivacyMode.STRICT_PRIVATE:
        if strict_allow_public_external and classes == frozenset({DataClass.PUBLIC}):
            return EgressDecision(True, False, "strict_public_only_opt_in")
        return EgressDecision(False, False, "strict_private_mode")

    if DataClass.SECRET in provider_allowed:
        provider_allowed = provider_allowed - {DataClass.SECRET}
    blocked = classes - provider_allowed
    if blocked:
        names = ",".join(sorted(c.value for c in blocked))
        return EgressDecision(False, False, f"class_not_granted:{names}")

    return EgressDecision(True, classes != frozenset({DataClass.PUBLIC}), "cloud_mode_granted")
