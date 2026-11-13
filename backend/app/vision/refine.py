"""Optional model refinement of the query text only.

The deterministic parser has already fixed dates, colours, labels, media and limit; a model may only
rewrite `PhotoQuery.text` (the phrase used for embedding similarity on the device). Nothing it returns
can change any other field. With no gateway, no permitted model or any failure, the owner's own
words stay as the text.
"""

from __future__ import annotations

import logging
from typing import Any

from app.core.types import AgentId, DataClass, PrivacyMode, TaskClass
from app.providers.types import ChatMessage, ChatRequest, NoPermittedModel, ProviderError

log = logging.getLogger(__name__)

SYSTEM = (
    "Rewrite the user's photo search request as one short English phrase describing what the photo shows "
    "(objects, colours, scene). Leave out dates and counts. Output only the phrase."
)
MAX_REFINED = 200


def accept(raw: str, original: str) -> str | None:
    """The refined phrase if it is a single plain line of reasonable length, else None."""
    text = raw.strip().strip("\"'“”‘’").strip()
    if not text or "\n" in text or len(text) > MAX_REFINED:
        return None
    return text if text.casefold() != original.strip().casefold() else None


async def refine_query_text(
    gateway: Any | None, text: str, *, privacy_mode: PrivacyMode, agent: AgentId = AgentId.VISION
) -> str | None:
    """A model-refined `text`, or None when refinement is unavailable or its answer is unusable."""
    if gateway is None:
        return None
    request = ChatRequest(
        task=TaskClass.ROUTINE_CHAT,
        messages=(ChatMessage(role="system", content=SYSTEM), ChatMessage(role="user", content=text)),
        max_output_tokens=60,
        temperature=0.0,
        data_classes=frozenset({DataClass.PERSONAL}),
        privacy_mode=privacy_mode,
        agent=agent,
        timeout_s=8.0,
    )
    try:
        response = await gateway.chat(request)
    except (NoPermittedModel, ProviderError, TimeoutError) as exc:
        log.info("photo query refinement skipped", extra={"reason": type(exc).__name__})
        return None
    except Exception as exc:  # a refinement must never break a search
        log.warning("photo query refinement failed", extra={"error_type": type(exc).__name__})
        return None
    return accept(response.text, text)
