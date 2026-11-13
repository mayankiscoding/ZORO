"""Loads `config/shopping_providers.yaml`. Provider URLs live only there (CLAUDE.md rule 7)."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Literal
from urllib.parse import quote, quote_plus, urlsplit

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.core.errors import ConfigError

FILE_NAME = "shopping_providers.yaml"


class HandoffConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    url: str | None = None
    verified: bool = False

    @field_validator("url")
    @classmethod
    def _https_only(cls, value: str | None) -> str | None:
        if value is not None and not value.startswith("https://"):
            raise ValueError("handoff URLs must be https")
        return value

    def render(self, query: str | None) -> str | None:
        """Fill `{query}` (URL-encoded) or `{query_slug}`; a template with a placeholder and no query
        falls back to the site root."""
        if self.url is None:
            return None
        if "{" not in self.url:
            return self.url
        if not query:
            parts = urlsplit(self.url)
            return f"{parts.scheme}://{parts.netloc}/"
        slug = quote("-".join(query.lower().split()), safe="-")
        return self.url.replace("{query}", quote_plus(query)).replace("{query_slug}", slug)


class ProviderConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str
    kind: Literal["mcp", "flipkart_affiliate", "partnership", "handoff"]
    category: str = "general"
    handoff: HandoffConfig = Field(default_factory=HandoffConfig)
    docs_url: str | None = None
    # mcp
    mcp_url: str | None = None
    oauth_redirect_uri: str | None = None
    tool_map: dict[str, str] = Field(default_factory=dict)
    forbidden_tools: list[str] = Field(default_factory=list)
    # flipkart
    base_url: str | None = None
    endpoints_verified: bool = False
    credential_env: list[str] = Field(default_factory=list)
    # partnership
    partnership_note: str = ""


class ShoppingConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    version: int = 1
    staleness_minutes: dict[str, int] = Field(
        default_factory=lambda: {"provider_api": 30, "user_reported": 1440, "user_screenshot_ocr": 720}
    )
    providers: dict[str, ProviderConfig] = Field(default_factory=dict)


def parse_config(raw: dict[str, Any]) -> ShoppingConfig:
    try:
        return ShoppingConfig.model_validate(raw)
    except ValueError as exc:
        raise ConfigError(f"{FILE_NAME} is not valid: {exc}") from exc


def load_config(config_dir: Path) -> ShoppingConfig:
    """A missing file means no providers (every capability then reads unavailable)."""
    path = config_dir / FILE_NAME
    if not path.exists():
        return ShoppingConfig()
    with path.open(encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}
    if not isinstance(raw, dict):
        raise ConfigError(f"{FILE_NAME} must be a mapping")
    return parse_config(raw)
