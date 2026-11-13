"""`local-hash-v1`: deterministic, offline text embedder (character n-gram feature hashing).

Text is NFKC-normalised and case-folded, padded with spaces, split into character 2-, 3- and 4-grams;
each n-gram is hashed with BLAKE2b (stable across processes, unlike `hash()`) into one of 256 buckets
with a hash-derived sign, and the vector is L2-normalised. Empty text gives the zero vector.
"""

from __future__ import annotations

import hashlib
import math
import unicodedata
from collections.abc import Iterable

LOCAL_HASH_MODEL_ID = "local-hash-v1"
LOCAL_HASH_DIMS = 256
_NGRAMS = (2, 3, 4)


def _features(text: str) -> Iterable[str]:
    norm = " ".join(unicodedata.normalize("NFKC", text).casefold().split())
    if not norm:
        return
    padded = f" {norm} "
    for n in _NGRAMS:
        for i in range(len(padded) - n + 1):
            yield f"{n}:{padded[i : i + n]}"


def local_hash_embed_one(text: str, dims: int = LOCAL_HASH_DIMS) -> list[float]:
    vec = [0.0] * dims
    for feat in _features(text):
        digest = hashlib.blake2b(feat.encode("utf-8"), digest_size=8).digest()
        h = int.from_bytes(digest, "big")
        vec[h % dims] += 1.0 if (h >> 63) & 1 else -1.0
    norm = math.sqrt(sum(v * v for v in vec))
    if norm == 0.0:
        return vec
    return [v / norm for v in vec]


def local_hash_embed(texts: Iterable[str], dims: int = LOCAL_HASH_DIMS) -> list[list[float]]:
    return [local_hash_embed_one(t, dims) for t in texts]
