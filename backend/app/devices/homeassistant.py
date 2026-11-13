"""Home Assistant over its official REST API (backend-executed).

`Authorization: Bearer <long-lived token>`; services are called with
`POST /api/services/<domain>/<service>` and a JSON body such as `{"entity_id": [...]}`; state is read
with `GET /api/states/<entity_id>`. Enabled only when HOME_ASSISTANT_URL and HOME_ASSISTANT_TOKEN
are set, and only for entities the owner allowlisted (HOME_ASSISTANT_ENTITIES, or
`<config_dir>/home_assistant.yaml`). Locks and alarm panels are never callable from here.
"""

from __future__ import annotations

import logging
import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx
import yaml

from app.core.clock import Clock
from app.core.errors import BadRequest, Forbidden, NotFound, Unavailable, ZoroError

log = logging.getLogger(__name__)

ENV_URL = "HOME_ASSISTANT_URL"
ENV_TOKEN = "HOME_ASSISTANT_TOKEN"  # noqa: S105 - the variable's name, not a secret
ENV_ENTITIES = "HOME_ASSISTANT_ENTITIES"
_ENTITY = re.compile(r"^[a-z_]+\.[a-z0-9_]+$")

#: Services that may be called, per domain. Anything else is refused before any request is made.
ALLOWED_SERVICES: dict[str, frozenset[str]] = {
    "light": frozenset({"turn_on", "turn_off", "toggle"}),
    "switch": frozenset({"turn_on", "turn_off", "toggle"}),
    "fan": frozenset({"turn_on", "turn_off", "toggle"}),
    "scene": frozenset({"turn_on"}),
    "script": frozenset({"turn_on"}),
    "cover": frozenset({"open_cover", "close_cover", "stop_cover"}),
    "media_player": frozenset({"media_play", "media_pause", "turn_on", "turn_off"}),
    "climate": frozenset({"turn_on", "turn_off", "set_temperature"}),
}


class HomeAssistantError(ZoroError):
    code = "home_assistant_error"
    status = 502
    default_message = "Home Assistant could not do that."


@dataclass(frozen=True)
class HAEntity:
    entity_id: str
    name: str
    aliases: tuple[str, ...] = ()

    @property
    def domain(self) -> str:
        return self.entity_id.split(".", 1)[0]


def _default_name(entity_id: str) -> str:
    return entity_id.split(".", 1)[1].replace("_", " ").capitalize()


def _parse_env_entities(raw: str) -> list[HAEntity]:
    """ "light.living_room=Living room|baithak, switch.fan" -> entities (bad ids are skipped)."""
    entities: list[HAEntity] = []
    for item in (part.strip() for part in raw.split(",")):
        entity_id, _, names = item.partition("=")
        entity_id = entity_id.strip().lower()
        if not _ENTITY.match(entity_id):
            continue
        labels = [n.strip() for n in names.split("|") if n.strip()]
        name = labels[0] if labels else _default_name(entity_id)
        entities.append(HAEntity(entity_id, name, tuple(labels[1:])))
    return entities


def _parse_yaml_entities(path: Path) -> list[HAEntity]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except FileNotFoundError:
        return []
    except (OSError, yaml.YAMLError):
        log.error("home_assistant.yaml is not valid; no entities allowlisted from it")
        return []
    entities: list[HAEntity] = []
    for item in data.get("entities", []) if isinstance(data, dict) else []:
        if not isinstance(item, dict) or not _ENTITY.match(str(item.get("id", "")).lower()):
            continue
        entity_id = str(item["id"]).lower()
        aliases = tuple(str(a) for a in item.get("aliases", []) or [] if str(a).strip())
        entities.append(HAEntity(entity_id, str(item.get("name") or _default_name(entity_id)), aliases))
    return entities


@dataclass(frozen=True)
class HomeAssistantConfig:
    url: str | None
    token: str | None
    entities: tuple[HAEntity, ...] = ()

    def __repr__(self) -> str:  # never print the token
        return f"HomeAssistantConfig(url={self.url!r}, token={'set' if self.token else None}, entities={len(self.entities)})"

    @property
    def enabled(self) -> bool:
        return bool(self.url and self.token)

    def entity(self, entity_id: str) -> HAEntity | None:
        return next((e for e in self.entities if e.entity_id == entity_id), None)

    @classmethod
    def from_env(
        cls, env: Mapping[str, str] | None = None, config_dir: Path | None = None
    ) -> HomeAssistantConfig:
        env = os.environ if env is None else env
        url = (env.get(ENV_URL) or "").strip().rstrip("/") or None
        if url is not None and not url.startswith(("http://", "https://")):
            log.error("HOME_ASSISTANT_URL must start with http:// or https://; integration disabled")
            url = None
        token = (env.get(ENV_TOKEN) or "").strip() or None
        found = _parse_env_entities(env.get(ENV_ENTITIES, ""))
        if config_dir is not None:
            found += _parse_yaml_entities(config_dir / "home_assistant.yaml")
        unique = {e.entity_id: e for e in reversed(found)}
        return cls(url, token, tuple(sorted(unique.values(), key=lambda e: e.entity_id)))


class HomeAssistantClient:
    """Registered as service ``home_assistant``. Every request has a timeout; nothing is retried."""

    def __init__(
        self, config: HomeAssistantConfig, *, clock: Clock, transport: httpx.AsyncBaseTransport | None = None
    ) -> None:
        self.config = config
        self._clock = clock
        self._transport = transport
        self._http: httpx.AsyncClient | None = None

    def _client(self) -> httpx.AsyncClient:
        if not self.config.enabled:
            raise Unavailable(
                "Home Assistant is not connected. Set HOME_ASSISTANT_URL and HOME_ASSISTANT_TOKEN.",
                code="home_assistant_not_configured",
            )
        if self._http is None:
            self._http = httpx.AsyncClient(
                base_url=str(self.config.url),
                headers={"Authorization": f"Bearer {self.config.token}", "Content-Type": "application/json"},
                timeout=httpx.Timeout(10.0, connect=5.0),
                transport=self._transport,
                follow_redirects=False,
            )
        return self._http

    def require_allowed(self, entity_ids: list[str], domain: str | None = None) -> list[HAEntity]:
        self._client()  # raises when the integration is not configured
        if not entity_ids:
            raise BadRequest("Name at least one allowlisted device.", code="no_entities")
        entities: list[HAEntity] = []
        for entity_id in entity_ids:
            entity = self.config.entity(entity_id)
            if entity is None:
                raise Forbidden(
                    f"{entity_id} is not on the Home Assistant allowlist.", code="entity_not_allowlisted"
                )
            if domain is not None and entity.domain != domain:
                raise BadRequest(f"{entity_id} is not a {domain} entity.", code="entity_domain_mismatch")
            entities.append(entity)
        return entities

    async def _request(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        http = self._client()
        try:
            response = await http.request(method, path, json=body)
        except httpx.TimeoutException:
            raise Unavailable(
                "Home Assistant did not answer in time.", code="home_assistant_timeout"
            ) from None
        except httpx.HTTPError:
            raise Unavailable(
                "Home Assistant cannot be reached.", code="home_assistant_unreachable"
            ) from None
        if response.status_code in (401, 403):
            raise HomeAssistantError("Home Assistant refused the token.", code="home_assistant_unauthorized")
        if response.status_code == 404:
            raise NotFound(
                "Home Assistant does not know that entity or service.", code="home_assistant_not_found"
            )
        if response.status_code == 400:
            raise BadRequest("Home Assistant rejected the request.", code="home_assistant_rejected")
        if response.status_code >= 300:
            raise HomeAssistantError(f"Home Assistant answered HTTP {response.status_code}.")
        try:
            return response.json()
        except ValueError:
            raise HomeAssistantError(
                "Home Assistant sent a malformed answer.", code="home_assistant_bad_response"
            ) from None

    async def get_state(self, entity_id: str) -> dict[str, Any]:
        self.require_allowed([entity_id])
        data = await self._request("GET", f"/api/states/{entity_id}")
        if not isinstance(data, dict) or "state" not in data:
            raise HomeAssistantError(
                "Home Assistant sent a malformed state.", code="home_assistant_bad_response"
            )
        return data

    async def call_service(
        self, domain: str, service: str, entity_ids: list[str], data: dict[str, Any]
    ) -> list[dict[str, Any]]:
        if service not in ALLOWED_SERVICES.get(domain, frozenset()):
            raise Forbidden(f"{domain}.{service} is not an allowed action.", code="service_not_allowed")
        self.require_allowed(entity_ids, domain)
        body: dict[str, Any] = {"entity_id": entity_ids, **data}
        result = await self._request("POST", f"/api/services/{domain}/{service}", body)
        return [item for item in result if isinstance(item, dict)] if isinstance(result, list) else []

    def now(self) -> datetime:
        return self._clock.now()

    async def aclose(self) -> None:
        if self._http is not None:
            await self._http.aclose()
            self._http = None
