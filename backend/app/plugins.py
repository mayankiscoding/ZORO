"""Plugin registry and kernel wiring.

Every backend package registers itself through ``app/<pkg>/plugin.py: register(reg)``. Nobody edits
a shared file to add a tool, router, intent, capability or permission. `build_kernel` creates the
registry with the kernel services already provided; `load_plugins` then lets each package add to it.
"""

from __future__ import annotations

import importlib
import inspect
import logging
from collections.abc import Awaitable, Callable, Iterable, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from fastapi import APIRouter

from app.core.clock import Clock, SystemClock
from app.core.objects import build_object_store
from app.core.settings import Settings
from app.core.types import AgentId, DevicePlatform, PrivacyMode
from app.db.discovery import module_exists
from app.db.session import Database
from app.schemas.security import Capability
from app.security.admin import SecurityAdmin
from app.security.approval_routing import ApprovalRouter
from app.security.approvals import ApprovalService
from app.security.audit import AuditLog
from app.security.crypto import FieldCipher
from app.security.devices import DeviceRegistry
from app.security.permissions import CLOUD_FINANCIAL, CLOUD_HEALTH, CLOUD_SENSITIVE, PermissionService
from app.security.policy import PolicyConfigSource, PolicyEngine
from app.security.privacy import PrivacyStateService
from app.security.proofs import ProofVerifier
from app.security.secrets import SecretStore
from app.security.sessions import SessionService
from app.security.state import KillSwitch, SecuritySettingsStore
from app.tools.dispatcher import DeviceDispatcher, NullDeviceDispatcher
from app.tools.executor import ToolExecutor
from app.tools.intents import IntentRegistry, IntentSpec
from app.tools.journal import ToolCallJournal
from app.tools.ratelimit import TokenBucketRateLimiter
from app.tools.registry import ToolRegistry
from app.tools.spec import EventEmitter, ToolContext, ToolSpec
from app.tools.state import ConversationStateStore

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

log = logging.getLogger(__name__)

PLUGIN_MODULES: tuple[str, ...] = (
    "app.providers.plugin",
    "app.agents.plugin",
    "app.orchestrator.plugin",
    "app.mcp.plugin",
    "app.devices.plugin",
    "app.memory.plugin",
    "app.documents.plugin",
    "app.finance.plugin",
    "app.investment.plugin",
    "app.shopping.plugin",
    "app.research.plugin",
    "app.fitness.plugin",
    "app.vision.plugin",
    "app.voice.plugin",
    "app.music.plugin",
    "app.communications.plugin",
    "app.automation.plugin",
)

# Policy, approvals, audit and identity are never swappable after start.
_FIXED_SERVICES = frozenset(
    {
        "policy", "approvals", "approval_router", "audit", "devices", "sessions", "permissions",
        "kill_switch", "privacy_state", "proofs", "tool_executor", "tool_registry", "security_admin",
        "cipher", "secrets",
    }
)  # fmt: skip

Hook = Callable[[], Awaitable[None] | None]
CapabilityProvider = Callable[[], Capability | Iterable[Capability]]


class PluginError(RuntimeError):
    pass


@dataclass(frozen=True)
class Mount:
    """An ASGI app served outside `/v1` (for example the MCP gateway at `/mcp`)."""

    path: str
    app: Any
    guarded: bool = True  # answers 503 while the kill switch is on


class ServiceNotFound(PluginError, KeyError):
    """Unknown service name. Also a `KeyError` / `LookupError` for callers that catch those."""

    def __str__(self) -> str:
        return str(self.args[0]) if self.args else "service not found"


class CapabilityRegistry:
    """What ZORO can do right now, stated honestly. Entries are static `Capability` objects or
    providers evaluated on every read (for status that depends on credentials or devices)."""

    def __init__(self) -> None:
        self._static: dict[str, Capability] = {}
        self._providers: list[CapabilityProvider] = []

    def add(self, capability: Capability | CapabilityProvider) -> None:
        if isinstance(capability, Capability):
            if capability.id in self._static:
                raise PluginError(f"capability already registered: {capability.id}")
            self._static[capability.id] = capability
        elif callable(capability):
            self._providers.append(capability)
        else:
            raise PluginError("add_capability takes a Capability or a callable returning capabilities")

    def all(self, *, domain: str | None = None) -> list[Capability]:
        merged = dict(self._static)
        for provider in self._providers:
            produced = provider()
            for capability in [produced] if isinstance(produced, Capability) else list(produced):
                merged[capability.id] = capability
        items = sorted(merged.values(), key=lambda capability: (capability.domain, capability.id))
        return [c for c in items if domain is None or c.domain == domain]

    def get(self, capability_id: str) -> Capability | None:
        return next((c for c in self.all() if c.id == capability_id), None)


class PluginRegistry:
    def __init__(self) -> None:
        self.tools = ToolRegistry()
        self.intents = IntentRegistry()
        self.capabilities = CapabilityRegistry()
        self.routers: list[APIRouter] = []
        self.mounts: list[Mount] = []
        self.startup_hooks: list[Hook] = []
        self.shutdown_hooks: list[Hook] = []
        self.loaded_plugins: list[str] = []
        self.skipped_plugins: list[str] = []
        self._services: dict[str, Any] = {}
        self._dispatcher: DeviceDispatcher = NullDeviceDispatcher()

    # ------------------------------------------------------------ what packages call

    def add_tool(self, spec: ToolSpec) -> None:
        self.tools.register(spec)

    def add_intent(self, spec: IntentSpec) -> None:
        self.intents.register(spec)

    def add_router(self, router: APIRouter) -> None:
        """Mounted under `/v1` (so a router's own prefix is e.g. "/finance")."""
        self.routers.append(router)

    def add_mount(self, path: str, app: Any, *, guarded: bool = True) -> None:
        """Serve an ASGI app at `path` (outside `/v1`). The host runs the app's lifespan with
        its own, and stops it while the kill switch is on unless `guarded` is false."""
        if not path.startswith("/") or path == "/" or path.rstrip("/") == "/v1":
            raise PluginError(f"a mount needs its own path prefix, got {path!r}")
        path = path.rstrip("/")
        if any(m.path == path for m in self.mounts):
            raise PluginError(f"path already mounted: {path}")
        self.mounts.append(Mount(path, app, guarded))

    def add_capability(self, cap: Capability | CapabilityProvider) -> None:
        self.capabilities.add(cap)

    def add_permission(self, key: str, title: str, default: bool = False) -> None:
        self.service("permissions").declare(key, title, default)

    def add_startup(self, fn: Hook) -> None:
        self.startup_hooks.append(fn)

    def add_shutdown(self, fn: Hook) -> None:
        self.shutdown_hooks.append(fn)

    def set_device_dispatcher(self, dispatcher: DeviceDispatcher) -> None:
        self._dispatcher = dispatcher
        executor = self._services.get("tool_executor")
        if executor is not None:
            executor.set_dispatcher(dispatcher)

    @property
    def device_dispatcher(self) -> DeviceDispatcher:
        return self._dispatcher

    def provide(self, name: str, obj: Any) -> None:
        """Publish a service for other packages. A name can be provided once."""
        if name in self._services:
            raise PluginError(f"service already provided: {name}")
        self._services[name] = obj

    def replace(self, name: str, obj: Any) -> None:
        """Swap a provided service (integration tests put a scripted model gateway here). The
        kernel's security services are fixed once the registry is built and cannot be swapped."""
        if name not in self._services:
            raise ServiceNotFound(f"no service named {name!r} to replace")
        if name in _FIXED_SERVICES:
            raise PluginError(f"service {name!r} cannot be replaced")
        self._services[name] = obj

    def service(self, name: str) -> Any:
        try:
            return self._services[name]
        except KeyError:
            raise ServiceNotFound(f"no service named {name!r} (is its plugin loaded?)") from None

    def has_service(self, name: str) -> bool:
        return name in self._services

    # ------------------------------------------------------------ helpers for orchestration

    def tool_context(
        self,
        *,
        turn_id: str,
        agent: AgentId,
        device_id: str | None = None,
        conversation_id: str | None = None,
        privacy_mode: PrivacyMode = PrivacyMode.STRICT_PRIVATE,
        lang: str = "en",
        timezone: str = "Asia/Kolkata",
        tainted: bool = False,
        user_initiated: bool = False,
        emitter: EventEmitter | None = None,
        target_device_id: str | None = None,
        target_platform: DevicePlatform | None = None,
    ) -> ToolContext:
        """A `ToolContext` wired to the registered services (gateway included once provided)."""
        return ToolContext(
            turn_id=turn_id,
            agent=agent,
            db=self.service("session_factory"),
            settings=self.service("settings"),
            audit=self.service("audit"),
            secrets=self.service("secrets"),
            objects=self.service("objects"),
            conversation_id=conversation_id,
            device_id=device_id,
            privacy_mode=privacy_mode,
            lang=lang,
            timezone=timezone,
            tainted=tainted,
            user_initiated=user_initiated,
            gateway=self._services.get("gateway"),
            state=self._services.get("conversation_state"),
            clock=self.service("clock"),
            emitter=emitter,
            target_device_id=target_device_id,
            target_platform=target_platform,
        )

    async def run_startup(self) -> None:
        for hook in self.startup_hooks:
            await _call(hook)

    async def run_shutdown(self) -> None:
        for hook in reversed(self.shutdown_hooks):
            try:
                await _call(hook)
            except Exception as exc:
                log.error("shutdown hook failed", extra={"error_type": type(exc).__name__})


async def _call(hook: Hook) -> None:
    result = hook()
    if inspect.isawaitable(result):
        await result


def load_plugins(reg: PluginRegistry, modules: Sequence[str] | None = None) -> list[str]:
    """Import each plugin module in order and call its `register(reg)`.

    A module that does not exist yet is skipped with a log line. An error raised while importing
    or registering an existing plugin propagates: a broken package must not start silently.
    """
    for name in modules if modules is not None else PLUGIN_MODULES:
        if not module_exists(name):
            log.info("plugin not present, skipped", extra={"plugin": name})
            reg.skipped_plugins.append(name)
            continue
        module = importlib.import_module(name)
        register = getattr(module, "register", None)
        if not callable(register):
            raise PluginError(f"{name} has no register(reg) function")
        register(reg)
        reg.loaded_plugins.append(name)
        log.info("plugin registered", extra={"plugin": name})
    return list(reg.loaded_plugins)


def build_kernel(
    settings: Settings,
    *,
    clock: Clock | None = None,
    database: Database | None = None,
) -> PluginRegistry:
    """Create the registry and provide every kernel service. No I/O happens here (tables are
    created by `init_db` at startup), so this is safe to call at import time of an ASGI app."""
    clock = clock or SystemClock()
    database = database or Database.from_url(settings.database_url)
    session_factory: async_sessionmaker[AsyncSession] = database.session_factory
    signing_key = settings.signing_key()
    cipher = FieldCipher(settings.data_key_bytes())
    policy_source = PolicyConfigSource(settings.config_dir / "policy.yaml")

    reg = PluginRegistry()
    audit = AuditLog(session_factory, clock)
    devices = DeviceRegistry(session_factory, pepper=signing_key, clock=clock)
    sessions = SessionService(
        session_factory,
        devices,
        secret=signing_key,
        ttl_seconds=settings.access_token_ttl_seconds,
        clock=clock,
    )
    permissions = PermissionService(session_factory, clock)
    kill_switch = KillSwitch(session_factory, clock)
    security_store = SecuritySettingsStore(session_factory, clock)
    privacy = PrivacyStateService(
        security_store,
        permissions,
        default_mode=settings.default_privacy_mode,
        config=policy_source.current,
        kill_switch=kill_switch,
    )
    proofs = ProofVerifier(session_factory, devices, clock=clock)
    approvals = ApprovalService(session_factory, devices, cipher, clock)
    rate_limiter = TokenBucketRateLimiter()
    policy = PolicyEngine(
        kill_switch=kill_switch,
        devices=devices,
        permissions=permissions,
        rate_limiter=rate_limiter,
        config=policy_source.current,
    )
    executor = ToolExecutor(
        registry=reg.tools,
        policy=policy,
        approvals=approvals,
        audit=audit,
        devices=devices,
        journal=ToolCallJournal(session_factory, cipher, clock),
        clock=clock,
        dispatcher=reg.device_dispatcher,
    )
    admin = SecurityAdmin(
        devices=devices,
        proofs=proofs,
        permissions=permissions,
        privacy=privacy,
        kill_switch=kill_switch,
        audit=audit,
        config=policy_source.current,
        online=lambda: reg.device_dispatcher,
    )

    for name, obj in {
        "settings": settings,
        "clock": clock,
        "database": database,
        "session_factory": session_factory,
        "cipher": cipher,
        "audit": audit,
        "secrets": SecretStore(session_factory, cipher, clock),
        "conversation_state": ConversationStateStore(session_factory, cipher, clock),
        "objects": build_object_store(settings),
        "devices": devices,
        "sessions": sessions,
        "permissions": permissions,
        "kill_switch": kill_switch,
        "privacy_state": privacy,
        "proofs": proofs,
        "approvals": approvals,
        "approval_router": ApprovalRouter(approvals),
        "rate_limiter": rate_limiter,
        "policy": policy,
        "policy_config": policy_source,
        "tool_registry": reg.tools,
        "tool_executor": executor,
        "intents": reg.intents,
        "capabilities": reg.capabilities,
        "security_admin": admin,
    }.items():
        reg.provide(name, obj)

    reg.add_permission(CLOUD_SENSITIVE, "Send sensitive personal data to approved cloud models", False)
    reg.add_permission(CLOUD_FINANCIAL, "Send financial data to approved cloud models", False)
    reg.add_permission(CLOUD_HEALTH, "Send health and fitness data to approved cloud models", False)
    return reg
