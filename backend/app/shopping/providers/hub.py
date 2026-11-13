"""Builds every configured provider and answers "which providers exist and how well are they backed"."""

from __future__ import annotations

from collections.abc import Callable, Mapping

from app.core.clock import Clock
from app.core.types import CapabilityStatus
from app.schemas.security import Capability
from app.shopping.config import ProviderConfig, ShoppingConfig
from app.shopping.providers.base import ShoppingProvider
from app.shopping.providers.flipkart import ID_ENV, TOKEN_ENV, FlipkartAffiliateProvider
from app.shopping.providers.handoff import HandoffProvider, PartnershipProvider
from app.shopping.providers.swiggy import McpToolClient, SwiggyInstamartProvider
from app.shopping.types import ProviderInfo, ProviderMethod

McpClientFactory = Callable[[str, ProviderConfig], McpToolClient]
CALLBACK_PATH = "/v1/shopping/providers/{provider}/oauth/callback"


class ProviderHub:
    def __init__(self, providers: Mapping[str, ShoppingProvider]) -> None:
        self._providers = dict(providers)
        self._status: dict[str, CapabilityStatus] = {}

    @classmethod
    def from_config(
        cls,
        config: ShoppingConfig,
        *,
        clock: Clock | None = None,
        env: Mapping[str, str] | None = None,
        mcp_client_factory: McpClientFactory | None = None,
    ) -> ProviderHub:
        built: dict[str, ShoppingProvider] = {}
        for pid, pc in config.providers.items():
            provider: ShoppingProvider
            if pc.kind == "mcp":
                if mcp_client_factory is None or not pc.mcp_url:
                    provider = HandoffProvider(pid, pc, clock=clock)
                else:
                    provider = SwiggyInstamartProvider(pid, pc, mcp_client_factory(pid, pc), clock=clock)
            elif pc.kind == "flipkart_affiliate":
                provider = FlipkartAffiliateProvider(pid, pc, clock=clock, env=env)
            elif pc.kind == "partnership":
                provider = PartnershipProvider(pid, pc, clock=clock)
            else:
                provider = HandoffProvider(pid, pc, clock=clock)
            built[pid] = provider
        return cls(built)

    def get(self, provider_id: str) -> ShoppingProvider | None:
        return self._providers.get(provider_id)

    def all(self) -> list[ShoppingProvider]:
        return list(self._providers.values())

    def ids(self) -> list[str]:
        return list(self._providers)

    async def refresh_status(self) -> dict[str, CapabilityStatus]:
        self._status = {p.id: await p.status() for p in self._providers.values()}
        return dict(self._status)

    async def queryable(self) -> list[ShoppingProvider]:
        """Providers that can search through an official route right now."""
        statuses = await self.refresh_status()
        return [
            p
            for p in self._providers.values()
            if statuses[p.id] is CapabilityStatus.WORKING_INTEGRATION
            and p.level(ProviderMethod.SEARCH_PRODUCTS).value
            in ("official_api", "affiliate_search", "fully_integrated")
        ]

    async def infos(self) -> list[ProviderInfo]:
        return [await p.info() for p in self._providers.values()]

    def capabilities(self) -> list[Capability]:
        """Synchronous view for the capability registry (last refreshed status; static otherwise)."""
        caps: list[Capability] = []
        for p in self._providers.values():
            status = self._status.get(p.id) or _static_status(p)
            requires = list(p.config.credential_env) if p.config.kind == "flipkart_affiliate" else []
            if p.config.kind == "mcp":
                requires = ["owner connects account (OAuth)"]
            caps.append(
                Capability(
                    id=f"shopping.{p.id}",
                    title=p.config.title,
                    domain="shopping",
                    status=status,
                    integration_level=p.level(ProviderMethod.SEARCH_PRODUCTS),
                    requires=requires,
                    note=p.status_note(),
                )
            )
        return caps

    async def aclose(self) -> None:
        for p in self._providers.values():
            await p.aclose()


def _static_status(p: ShoppingProvider) -> CapabilityStatus:
    if isinstance(p, FlipkartAffiliateProvider):
        return CapabilityStatus.WORKING_INTEGRATION if p.configured else CapabilityStatus.REQUIRES_CREDENTIALS
    if isinstance(p, SwiggyInstamartProvider):
        return CapabilityStatus.REQUIRES_CREDENTIALS
    if isinstance(p, PartnershipProvider):
        return CapabilityStatus.REQUIRES_PARTNERSHIP
    return CapabilityStatus.MANUAL_USER_STEP


__all__ = ["CALLBACK_PATH", "ID_ENV", "TOKEN_ENV", "ProviderHub"]
