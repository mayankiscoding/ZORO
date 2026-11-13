"""`config/mcp_servers.yaml`: the MCP gateway's limits and device scopes, and the allowlist of
external MCP servers ZORO may call.

A missing or malformed file yields the safe defaults: no device may use any group, no external
server is enabled, stdio is off. The file reloads when it changes (no restart), except the
`expose` mappings, which become tools at startup.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Annotated, Literal
from urllib.parse import urlsplit

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

from app.core.types import AgentId, DataClass, Locality, RiskLevel

log = logging.getLogger(__name__)

ALL_GROUPS = "*"
_LOOPBACK = frozenset({"localhost", "127.0.0.1", "::1"})


class GatewayConfig(BaseModel):
    """Server side: who may reach which `/mcp/<group>` and the limits every call runs under."""

    model_config = ConfigDict(extra="forbid")

    max_risk: RiskLevel = RiskLevel.HIGH  # tools above this are not served over MCP at all
    call_timeout_s: float = Field(default=60, gt=0, le=600)
    requests_per_minute: int = Field(default=120, ge=1, le=10_000)  # per device and group
    max_result_bytes: int = Field(default=256 * 1024, ge=1024, le=8 * 1024 * 1024)
    max_request_bytes: int = Field(default=1024 * 1024, ge=1024, le=16 * 1024 * 1024)
    default_groups: list[str] = Field(default_factory=list)  # for every paired device; "*" = all
    devices: dict[str, list[str]] = Field(default_factory=dict)  # device id -> groups ("*" = all)

    def allows(self, device_id: str, group: str) -> bool:
        granted = [*self.default_groups, *self.devices.get(device_id, [])]
        return ALL_GROUPS in granted or group in granted


class AuthNone(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["none"] = "none"


class AuthBearer(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["bearer"] = "bearer"
    token_env: str = Field(pattern=r"^[A-Z][A-Z0-9_]{1,63}$")  # the token itself never lives in config


class AuthOAuth(BaseModel):
    """OAuth 2.1 + PKCE with dynamic client registration; tokens live in `SecretStore`."""

    model_config = ConfigDict(extra="forbid")
    kind: Literal["oauth"] = "oauth"
    redirect_uri: str
    scopes: list[str] = Field(default_factory=list)
    client_name: str = "ZORO"

    @model_validator(mode="after")
    def _redirect_is_safe(self) -> AuthOAuth:
        if not is_safe_url(self.redirect_uri):
            raise ValueError("redirect_uri must be https (http only for localhost)")
        return self


ExternalAuth = Annotated[AuthNone | AuthBearer | AuthOAuth, Field(discriminator="kind")]


class ExposedTool(BaseModel):
    """An explicit mapping that turns one allowed remote tool into a ZORO tool. Without one, no
    agent can reach the remote tool: nothing is auto-registered."""

    model_config = ConfigDict(extra="forbid")

    tool: str  # remote tool name; must be in the server's allowed_tools
    name: str = Field(pattern=r"^[a-z][a-z0-9_]{1,60}$")  # local: "mcpx.<server>.<name>"
    description: str = Field(min_length=1)
    agents: list[AgentId] = Field(min_length=1)
    risk: RiskLevel = RiskLevel.MEDIUM
    permission: str | None = None
    argument_data_classes: list[DataClass] = Field(default_factory=lambda: [DataClass.PERSONAL])
    result_data_classes: list[DataClass] = Field(default_factory=lambda: [DataClass.PERSONAL])


class ExternalServer(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(pattern=r"^[a-z][a-z0-9-]{1,40}$")
    title: str = ""
    transport: Literal["http", "stdio"] = "http"
    url: str | None = None  # Streamable HTTP endpoint
    command: str | None = None  # stdio only, absolute, and on the stdio allowlist
    args: list[str] = Field(default_factory=list)
    auth: ExternalAuth = Field(default_factory=AuthNone)
    allowed_tools: list[str] = Field(default_factory=list)
    data_classes: list[DataClass] = Field(default_factory=lambda: [DataClass.PUBLIC])  # it may receive
    locality: Locality = Locality.EXTERNAL
    enabled: bool = False
    timeout_s: float = Field(default=20, gt=0, le=120)
    max_result_bytes: int = Field(default=64 * 1024, ge=256, le=1024 * 1024)
    expose: list[ExposedTool] = Field(default_factory=list)

    @model_validator(mode="after")
    def _check(self) -> ExternalServer:
        if self.transport == "http":
            if not self.url or not is_safe_url(self.url):
                raise ValueError(f"{self.name}: url must be https (http only for localhost)")
        elif not self.command or not Path(self.command).is_absolute():
            raise ValueError(f"{self.name}: stdio needs an absolute command")
        if DataClass.SECRET in self.data_classes:
            raise ValueError(f"{self.name}: secret data is never sent to an MCP server")
        unknown = [e.tool for e in self.expose if e.tool not in self.allowed_tools]
        if unknown:
            raise ValueError(f"{self.name}: exposed tools are not in allowed_tools: {unknown}")
        return self

    @property
    def display_name(self) -> str:
        return self.title or self.name


class ClientsConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # Absolute commands that may be launched as stdio MCP servers. Empty: stdio is off.
    stdio_command_allowlist: list[str] = Field(default_factory=list)
    servers: list[ExternalServer] = Field(default_factory=list)

    @model_validator(mode="after")
    def _check(self) -> ClientsConfig:
        if any(not Path(c).is_absolute() for c in self.stdio_command_allowlist):
            raise ValueError("stdio_command_allowlist entries must be absolute paths")
        names = [s.name for s in self.servers]
        if len(names) != len(set(names)):
            raise ValueError("external MCP server names must be unique")
        return self

    def get(self, name: str) -> ExternalServer | None:
        return next((s for s in self.servers if s.name == name), None)


class McpConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    version: int = 1
    gateway: GatewayConfig = Field(default_factory=GatewayConfig)
    clients: ClientsConfig = Field(default_factory=ClientsConfig)


def is_safe_url(url: str) -> bool:
    """https anywhere; plain http only to the loopback interface."""
    parts = urlsplit(url)
    if not parts.hostname:
        return False
    return parts.scheme == "https" or (parts.scheme == "http" and parts.hostname in _LOOPBACK)


def load_mcp_config(path: Path) -> McpConfig:
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        return McpConfig.model_validate(raw)
    except FileNotFoundError:
        log.info("mcp_servers.yaml not found; MCP gateway closed to all devices")
    except (OSError, yaml.YAMLError, ValidationError) as exc:
        log.error(
            "mcp_servers.yaml is not valid; using safe defaults", extra={"error_type": type(exc).__name__}
        )
    return McpConfig()


class McpConfigSource:
    """Reloads the file when its modification time or size changes."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._stamp: tuple[int, int] | None = None
        self._config = McpConfig()
        self._loaded = False

    def current(self) -> McpConfig:
        try:
            stat = self.path.stat()
            stamp: tuple[int, int] | None = (stat.st_mtime_ns, stat.st_size)
        except OSError:
            stamp = None
        if not self._loaded or stamp != self._stamp:
            self._config = load_mcp_config(self.path)
            self._stamp = stamp
            self._loaded = True
        return self._config
