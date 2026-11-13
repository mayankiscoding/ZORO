"""Registers the fitness package.

Services: ``fitness_store`` (FitnessStore), ``fitness`` (FitnessService: the analytics),
``strava`` (StravaAdapter). Permission ``health.read``. Router ``/v1/fitness``.
"""

from __future__ import annotations

import importlib
import os
from collections.abc import Mapping
from typing import Any

import httpx

from app.fitness.api import build_router
from app.fitness.capabilities import static_capabilities, sync_capability
from app.fitness.intents import build_intents
from app.fitness.service import FitnessService
from app.fitness.store import FitnessStore
from app.fitness.strava import StravaAdapter
from app.fitness.tools import PERMISSION, build_tools


def install(
    reg: Any,
    *,
    env: Mapping[str, str] | None = None,
    strava_transport: httpx.AsyncBaseTransport | None = None,
) -> StravaAdapter:
    """`register` with an injectable environment and HTTP transport (for tests)."""
    require_device = importlib.import_module("app.api.deps").require_device
    clock = reg.service("clock")
    store = FitnessStore(reg.service("session_factory"), clock)
    service = FitnessService(store, clock)
    strava = StravaAdapter(
        env=os.environ if env is None else env,
        secrets=reg.service("secrets"),
        store=store,
        clock=clock,
        transport=strava_transport,
    )
    for name, obj in {"fitness_store": store, "fitness": service, "strava": strava}.items():
        reg.provide(name, obj)

    reg.add_permission(PERMISSION, "Let ZORO read your synced fitness and health summaries", True)
    for spec in build_tools(service):
        reg.add_tool(spec)
    for intent in build_intents():
        reg.add_intent(intent)
    reg.add_capability(lambda: sync_capability(store))
    reg.add_capability(strava.capability)
    for cap in static_capabilities():
        reg.add_capability(cap)
    reg.add_router(build_router(reg, service, strava, require_device))
    reg.add_startup(store.refresh_state)
    reg.add_startup(strava.refresh_state)
    return strava


def register(reg: Any) -> None:
    install(reg)
