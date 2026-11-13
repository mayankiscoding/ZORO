"""Embedding helpers: the gateway (egress-checked) with the local hashing embedder as the fallback.

Vectors of different models are not comparable, so every stored vector carries its model id and
search queries are embedded with every model that may have produced stored vectors.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

from app.core.types import DataClass, PrivacyMode
from app.memory.models import EMBED_DIM
from app.providers.embedding import LOCAL_HASH_DIMS, LOCAL_HASH_MODEL_ID, local_hash_embed

log = logging.getLogger(__name__)

assert LOCAL_HASH_DIMS == EMBED_DIM


@dataclass(frozen=True)
class Embedded:
    model: str
    vectors: list[list[float]]


async def embed_texts(
    gateway: Any | None,
    texts: list[str],
    data_classes: frozenset[DataClass],
    mode: PrivacyMode,
) -> Embedded:
    """Embed through the gateway with the data classes of the text; local embedder when there is
    no gateway, no permitted model, a failure, or a model whose width does not fit the column."""
    if gateway is not None and texts:
        try:
            result = await gateway.embed_with_model(texts, data_classes, mode)
            if result.dims == EMBED_DIM and len(result.vectors) == len(texts):
                return Embedded(str(result.model), [[float(x) for x in v] for v in result.vectors])
        except Exception as exc:
            log.info("embedding fell back to local", extra={"error_type": type(exc).__name__})
    return Embedded(LOCAL_HASH_MODEL_ID, local_hash_embed(texts))


async def query_vectors(
    gateway: Any | None, text: str, data_classes: frozenset[DataClass], mode: PrivacyMode
) -> dict[str, list[float]]:
    """model id -> query vector, for every model that could have embedded stored records."""
    local = local_hash_embed([text])[0]
    vectors = {LOCAL_HASH_MODEL_ID: local}
    if gateway is not None:
        embedded = await embed_texts(gateway, [text], data_classes, mode)
        vectors[embedded.model] = embedded.vectors[0]
    return vectors
