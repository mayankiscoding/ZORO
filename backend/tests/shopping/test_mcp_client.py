"""The SDK-backed client: tokens sealed in SecretStore; without tokens it never connects."""

from __future__ import annotations

from mcp.shared.auth import OAuthToken
from sqlalchemy import text

from app.plugins import PluginRegistry
from app.shopping.providers.mcp_client import SdkMcpClient, SecretTokenStorage
from app.shopping.providers.swiggy import SwiggyInstamartProvider

from .conftest import FakeMcpClient


async def test_token_storage_round_trip_is_sealed(shop: PluginRegistry) -> None:
    storage = SecretTokenStorage(shop.service("secrets"), "swiggy_instamart")
    client = SdkMcpClient("https://mcp.example.test/im", storage, "http://localhost/cb")
    assert await client.has_credentials() is False
    await storage.set_tokens(OAuthToken(access_token="at-secret-123", refresh_token="rt-secret-456"))
    assert await client.has_credentials() is True
    tokens = await storage.get_tokens()
    assert tokens is not None and tokens.access_token == "at-secret-123"
    async with shop.service("session_factory")() as session:
        raw = (await session.execute(text("select ciphertext from integration_credentials"))).scalars().all()
    assert raw and all("at-secret-123" not in r and "rt-secret-456" not in r for r in raw)
    await storage.clear()
    assert await client.has_credentials() is False


async def test_plugin_wires_the_fake_client(shop: PluginRegistry, fake_mcp: FakeMcpClient) -> None:
    provider = shop.service("shopping").hub.get("swiggy_instamart")
    assert isinstance(provider, SwiggyInstamartProvider)
    assert shop.has_service("shopping_shortlist")
