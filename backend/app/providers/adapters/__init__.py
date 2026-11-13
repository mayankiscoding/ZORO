"""Provider adapters over httpx (no vendor SDKs)."""

from app.providers.adapters.base import AdapterRequest, ProviderAdapter
from app.providers.adapters.gemini import GeminiAdapter
from app.providers.adapters.openai_compat import OpenAICompatAdapter

__all__ = ["AdapterRequest", "GeminiAdapter", "OpenAICompatAdapter", "ProviderAdapter"]
