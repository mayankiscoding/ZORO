"""Capability entries for fitness sources, stated honestly."""

from __future__ import annotations

from app.core.types import CapabilityStatus, IntegrationLevel
from app.fitness.store import FitnessStore
from app.schemas.security import Capability


def sync_capability(store: FitnessStore) -> Capability:
    if store.has_synced:
        return Capability(
            id="fitness.apple_health_sync",
            title="Apple Health sync",
            domain="fitness",
            status=CapabilityStatus.WORKING_LOCAL,
            integration_level=IntegrationLevel.FULLY_INTEGRATED,
            note="Daily aggregates and workouts synced from the iPhone; analytics run on this server.",
        )
    return Capability(
        id="fitness.apple_health_sync",
        title="Apple Health sync",
        domain="fitness",
        status=CapabilityStatus.MANUAL_USER_STEP,
        integration_level=IntegrationLevel.FULLY_INTEGRATED,
        requires=["Open ZORO on the iPhone and allow Health access"],
        note="Nothing has been synced yet, so fitness answers are unavailable.",
    )


def static_capabilities() -> list[Capability]:
    return [
        Capability(
            id="fitness.garmin",
            title="Garmin Connect",
            domain="fitness",
            status=CapabilityStatus.REQUIRES_PARTNERSHIP,
            integration_level=IntegrationLevel.UNAVAILABLE,
            requires=["Garmin Connect Developer Program (business application)"],
            note="Garmin's Health API sits behind a business programme; there is no personal-use route yet.",
        ),
        Capability(
            id="fitness.fitbit",
            title="Fitbit Web API",
            domain="fitness",
            status=CapabilityStatus.UNAVAILABLE,
            integration_level=IntegrationLevel.UNAVAILABLE,
            note="The Fitbit Web API was turned off on 2026-11-02 (HTTP 410). Use Apple Health on the iPhone.",
        ),
    ]
