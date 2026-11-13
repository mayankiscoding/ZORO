"""Test-only plugin: mounts whatever ASGI app the test put in `APP` at `/extra`."""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI

APP: Any = FastAPI()


def register(reg: Any) -> None:
    reg.add_mount("/extra", APP)
