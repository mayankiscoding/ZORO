"""Application factory. Run with: ``uv run --no-sync uvicorn app.main:create_app --factory``."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator, Sequence
from contextlib import AsyncExitStack, asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from app.api import auth as auth_api
from app.api import security as security_api
from app.api import system as system_api
from app.api.dependencies import block_when_killed
from app.api.errors import install_error_handlers
from app.core.clock import Clock
from app.core.logging import configure_logging
from app.core.settings import Settings, get_settings
from app.db.discovery import import_models, model_packages
from app.plugins import PLUGIN_MODULES, PluginRegistry, build_kernel, load_plugins

log = logging.getLogger(__name__)

API_PREFIX = "/v1"


class KillSwitchGuard:
    """Wraps a mounted ASGI app: nothing behind it answers while the kill switch is on."""

    def __init__(self, app: ASGIApp, registry: PluginRegistry) -> None:
        self._app = app
        self._registry = registry

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and await self._registry.service("kill_switch").is_on():
            body = {"code": "kill_switch_active", "message": "The kill switch is on.", "retryable": False}
            await JSONResponse(body, status_code=503)(scope, receive, send)
            return
        await self._app(scope, receive, send)


def _mount_lifespan(mounted: Any) -> Any | None:
    """The lifespan context of a mounted Starlette / FastAPI app, when it has one."""
    router = getattr(mounted, "router", None)
    context = getattr(router, "lifespan_context", None)
    return context(mounted) if callable(context) else None


def create_app(
    settings: Settings | None = None,
    *,
    plugin_modules: Sequence[str] | None = None,
    clock: Clock | None = None,
) -> FastAPI:
    """Build the ASGI app: kernel services, then every plugin that exists, then routers.

    `plugin_modules` and `clock` exist for tests; production uses `PLUGIN_MODULES` and real time.
    """
    settings = settings or get_settings()
    configure_logging(settings.log_level)
    modules = tuple(plugin_modules) if plugin_modules is not None else PLUGIN_MODULES

    registry: PluginRegistry = build_kernel(settings, clock=clock)
    load_plugins(registry, modules)
    packages = model_packages(modules)
    import_models(packages)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        database = registry.service("database")
        if settings.create_schema_on_start:
            await database.init(packages=packages)
        mounted = AsyncExitStack()
        for mount in registry.mounts:
            context = _mount_lifespan(mount.app)
            if context is not None:  # a mounted app's own startup and shutdown run with ours
                await mounted.enter_async_context(context)
        await registry.run_startup()
        log.info(
            "zoro started",
            extra={
                "env": settings.env,
                "plugins": len(registry.loaded_plugins),
                "tools": len(registry.tools),
                "database": database.engine.dialect.name,
            },
        )
        try:
            yield
        finally:
            await registry.run_shutdown()
            await mounted.aclose()
            await database.dispose()

    app = FastAPI(
        title="ZORO",
        version="0.1.0",
        lifespan=lifespan,
        docs_url=None if settings.is_production else "/docs",
        redoc_url=None,
        openapi_url=None if settings.is_production else "/openapi.json",
    )
    app.state.registry = registry
    app.state.settings = settings
    install_error_handlers(app)

    # Always answer: health, auth, security (the way back from a kill switch).
    app.include_router(system_api.health_router)
    app.include_router(auth_api.router, prefix=API_PREFIX)
    app.include_router(security_api.router, prefix=API_PREFIX)

    # Everything else stops while the kill switch is on.
    guarded = [Depends(block_when_killed)]
    app.include_router(system_api.capabilities_router, prefix=API_PREFIX, dependencies=guarded)
    app.include_router(system_api.approvals_router, prefix=API_PREFIX, dependencies=guarded)
    for router in registry.routers:
        app.include_router(router, prefix=API_PREFIX, dependencies=guarded)
    # ASGI apps served outside /v1 (the MCP gateway at /mcp/<group>).
    for mount in registry.mounts:
        app.mount(mount.path, KillSwitchGuard(mount.app, registry) if mount.guarded else mount.app)
    return app
