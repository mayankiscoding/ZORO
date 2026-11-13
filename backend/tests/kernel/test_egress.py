"""Exhaustive egress matrix for `decide_egress` (the privacy rule that lives in code)."""

from __future__ import annotations

from itertools import combinations

import pytest

from app.core.types import DataClass, Locality, PrivacyMode
from app.security.egress import DEFAULT_EXTERNAL_CLASSES, decide_egress

PRIVATE = [Locality.ON_DEVICE, Locality.LOCAL, Locality.PRIVATE_NETWORK]
NON_SECRET = [c for c in DataClass if c is not DataClass.SECRET]
ALL_SUBSETS = [
    frozenset(combo) for size in range(0, len(DataClass) + 1) for combo in combinations(DataClass, size)
]


@pytest.mark.parametrize("mode", list(PrivacyMode))
@pytest.mark.parametrize("locality", list(Locality))
@pytest.mark.parametrize("strict_public", [False, True])
def test_secret_never_leaves_anywhere(mode: PrivacyMode, locality: Locality, strict_public: bool) -> None:
    for classes in ALL_SUBSETS:
        if DataClass.SECRET not in classes:
            continue
        decision = decide_egress(
            mode=mode,
            data_classes=classes,
            locality=locality,
            provider_allowed=frozenset(DataClass),
            strict_allow_public_external=strict_public,
        )
        assert decision.allowed is False
        assert decision.reason == "secret_never_leaves"


@pytest.mark.parametrize("mode", list(PrivacyMode))
@pytest.mark.parametrize("locality", PRIVATE)
def test_private_localities_receive_everything_but_secrets(mode: PrivacyMode, locality: Locality) -> None:
    for classes in ALL_SUBSETS:
        if DataClass.SECRET in classes:
            continue
        decision = decide_egress(mode=mode, data_classes=classes, locality=locality)
        assert decision.allowed is True
        assert decision.redact is False
        assert decision.reason == "private_locality"


def test_strict_private_blocks_every_external_request() -> None:
    for classes in ALL_SUBSETS:
        if DataClass.SECRET in classes:
            continue
        decision = decide_egress(
            mode=PrivacyMode.STRICT_PRIVATE,
            data_classes=classes,
            locality=Locality.EXTERNAL,
            provider_allowed=frozenset(DataClass),
        )
        assert decision.allowed is False
        assert decision.reason == "strict_private_mode"


def test_strict_public_opt_in_allows_only_public_only_content() -> None:
    for classes in ALL_SUBSETS:
        if DataClass.SECRET in classes:
            continue
        decision = decide_egress(
            mode=PrivacyMode.STRICT_PRIVATE,
            data_classes=classes,
            locality=Locality.EXTERNAL,
            strict_allow_public_external=True,
        )
        if classes == frozenset({DataClass.PUBLIC}):
            assert decision.allowed is True
            assert decision.redact is False
            assert decision.reason == "strict_public_only_opt_in"
        else:
            assert decision.allowed is False  # includes the empty (unknown) classification


def test_unknown_classification_is_personal_not_public() -> None:
    cloud = decide_egress(mode=PrivacyMode.CLOUD_INTELLIGENCE, data_classes=[], locality=Locality.EXTERNAL)
    assert cloud.allowed is True
    assert cloud.redact is True
    narrow = decide_egress(
        mode=PrivacyMode.CLOUD_INTELLIGENCE,
        data_classes=[],
        locality=Locality.EXTERNAL,
        provider_allowed=frozenset({DataClass.PUBLIC}),
    )
    assert narrow.allowed is False
    assert narrow.reason == "class_not_granted:personal"


def test_cloud_mode_default_grant_matrix() -> None:
    for classes in ALL_SUBSETS:
        if DataClass.SECRET in classes or not classes:
            continue
        decision = decide_egress(
            mode=PrivacyMode.CLOUD_INTELLIGENCE, data_classes=classes, locality=Locality.EXTERNAL
        )
        blocked = classes - DEFAULT_EXTERNAL_CLASSES
        if blocked:
            assert decision.allowed is False
            assert decision.reason == "class_not_granted:" + ",".join(sorted(c.value for c in blocked))
        else:
            assert decision.allowed is True
            assert decision.redact is (classes != frozenset({DataClass.PUBLIC}))
            assert decision.reason == "cloud_mode_granted"


@pytest.mark.parametrize("extra", [DataClass.SENSITIVE, DataClass.FINANCIAL, DataClass.HEALTH])
def test_cloud_mode_with_a_widened_grant(extra: DataClass) -> None:
    allowed = DEFAULT_EXTERNAL_CLASSES | {extra}
    granted = decide_egress(
        mode=PrivacyMode.CLOUD_INTELLIGENCE,
        data_classes={DataClass.PERSONAL, extra},
        locality=Locality.EXTERNAL,
        provider_allowed=allowed,
    )
    assert granted.allowed is True
    assert granted.redact is True
    for other in NON_SECRET:
        if other in allowed:
            continue
        refused = decide_egress(
            mode=PrivacyMode.CLOUD_INTELLIGENCE,
            data_classes={other},
            locality=Locality.EXTERNAL,
            provider_allowed=allowed,
        )
        assert refused.allowed is False


def test_provider_can_never_be_granted_secret() -> None:
    decision = decide_egress(
        mode=PrivacyMode.CLOUD_INTELLIGENCE,
        data_classes={DataClass.PUBLIC},
        locality=Locality.EXTERNAL,
        provider_allowed=frozenset({DataClass.PUBLIC, DataClass.SECRET}),
    )
    assert decision.allowed is True
    assert decision.redact is False
