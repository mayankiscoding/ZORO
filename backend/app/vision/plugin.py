"""Registers the vision package: ``vision`` service (VisionService), tools ``vision.parse_photo_query``
and ``vision.show_photo_results``, intent ``vision.find_photos``, router ``/v1/vision``, permission
``vision.search``. The photo search itself is the device tool ``device.photos.search``."""

from __future__ import annotations

import importlib
from typing import Any

from app.vision.api import build_router
from app.vision.intents import build_intents
from app.vision.service import VisionService
from app.vision.tools import PERMISSION, build_tools


def register(reg: Any) -> None:
    require_device = importlib.import_module("app.api.deps").require_device
    service = VisionService(lambda: reg.service("gateway") if reg.has_service("gateway") else None)
    reg.provide("vision", service)
    reg.add_permission(
        PERMISSION,
        "Let ZORO turn your photo requests into searches on your device (no images leave it)",
        True,
    )
    for spec in build_tools(service):
        reg.add_tool(spec)
    for intent in build_intents():
        reg.add_intent(intent)
    reg.add_router(build_router(reg, service, require_device))
