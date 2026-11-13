"""Registers the automation package.

Services: ``automation_routines`` (RoutineService), ``automation_runner`` (RoutineRunner),
``automation_scheduler`` (RoutineScheduler, started and stopped by the plugin's hooks). Tools
``automation.list_routines`` (LOW), ``automation.run_routine`` and ``automation.save_routine`` (MEDIUM).
Router ``/v1/automations``. Permissions ``automation.read``, ``automation.run``, ``automation.manage``.
Set ``ZORO_AUTOMATION_SCHEDULER=off`` to keep the background scheduler from starting.
"""

from __future__ import annotations

import importlib
from typing import Any

from app.automation.api import build_router
from app.automation.intents import build_intents
from app.automation.runner import RoutineRunner, RunLimits
from app.automation.scheduler import RoutineScheduler
from app.automation.service import RoutineService
from app.automation.tools import MANAGE, READ, RUN, build_tools


def register(reg: Any) -> None:
    require_device = importlib.import_module("app.api.deps").require_device
    service = RoutineService(reg.service("session_factory"), reg.service("clock"), reg.tools)
    runner = RoutineRunner(reg, service, RunLimits())
    scheduler = RoutineScheduler(reg, runner)
    for name, obj in {
        "automation_routines": service,
        "automation_runner": runner,
        "automation_scheduler": scheduler,
    }.items():
        reg.provide(name, obj)
    reg.add_permission(READ, "Let ZORO list your saved routines", True)
    reg.add_permission(
        RUN, "Let ZORO run your saved routines (steps that change something still ask you)", True
    )
    reg.add_permission(MANAGE, "Let ZORO create and change routines (each change asks you first)", True)
    for spec in build_tools(service, runner):
        reg.add_tool(spec)
    for intent in build_intents():
        reg.add_intent(intent)
    reg.add_router(build_router(reg, service, runner, require_device))
    if reg.has_service("approval_router"):  # a paused run answers the generic decision route
        reg.service("approval_router").register("automation", runner.owns_approval, runner.decide_approval)
    reg.add_startup(scheduler.start)
    reg.add_shutdown(scheduler.stop)
