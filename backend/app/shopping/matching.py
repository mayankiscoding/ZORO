"""Equivalence matching across providers and variant resolution.

Exact means the same product: equal GTIN, or (when either side has no GTIN) the same brand, the
same normalised name and the same total size. Everything else that is close enough is a
substitute, reported with its reasons and never mixed into exact totals.
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from app.shopping.normalize import (
    normalize_brand,
    normalize_gtin,
    normalize_name,
    parse_pack,
    same_size,
)
from app.shopping.types import PackSize, Product, SModel, Variant

MatchKind = Literal["exact", "substitute", "none"]

_SUBSTITUTE_MIN = 0.3


class ItemIdentity(SModel):
    name: str
    brand: str | None = None
    pack: PackSize | None = None
    gtin: str | None = None


class MatchResult(SModel):
    kind: MatchKind
    confidence: float = Field(ge=0, le=1)
    reasons: list[str] = Field(default_factory=list)


def identity_of(product: Product, variant: Variant | None) -> ItemIdentity:
    pack = variant.pack if variant and variant.pack else parse_pack(variant.label if variant else None)
    if pack is None:
        pack = parse_pack(product.name)
    return ItemIdentity(name=product.name, brand=product.brand, pack=pack, gtin=product.gtin)


def _tokens(identity: ItemIdentity) -> set[str]:
    return set(normalize_name(identity.name, identity.brand).split())


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def match(reference: ItemIdentity, candidate: ItemIdentity) -> MatchResult:
    ref_gtin, cand_gtin = normalize_gtin(reference.gtin), normalize_gtin(candidate.gtin)
    if ref_gtin and cand_gtin:
        if ref_gtin == cand_gtin:
            return MatchResult(kind="exact", confidence=1.0, reasons=["same barcode"])
        gtin_differs = True
    else:
        gtin_differs = False

    same_brand = normalize_brand(reference.brand) == normalize_brand(candidate.brand)
    ref_tokens, cand_tokens = _tokens(reference), _tokens(candidate)
    name_equal = bool(ref_tokens) and ref_tokens == cand_tokens
    size_equal = same_size(reference.pack, candidate.pack)

    if not gtin_differs and same_brand and name_equal and size_equal and reference.brand:
        return MatchResult(kind="exact", confidence=0.95, reasons=["same brand, name and size"])

    similarity = _jaccard(ref_tokens, cand_tokens)
    if similarity < _SUBSTITUTE_MIN:
        return MatchResult(kind="none", confidence=0.0, reasons=["different product"])
    reasons: list[str] = []
    score = similarity
    if gtin_differs:
        reasons.append("different barcode")
        score *= 0.8
    if not same_brand:
        reasons.append("different brand")
        score *= 0.7
    if not name_equal:
        reasons.append("different name or flavour")
    if reference.pack is None or candidate.pack is None:
        reasons.append("size not stated")
        score *= 0.6
    elif not size_equal:
        reasons.append(
            f"different size ({reference.pack.total.normalize():f} {reference.pack.unit} vs "
            f"{candidate.pack.total.normalize():f} {candidate.pack.unit})"
            if reference.pack.unit == candidate.pack.unit
            else "different unit of measure"
        )
        score *= 0.7
    if not reasons:
        reasons.append("brand missing on one side")
        score *= 0.8
    return MatchResult(kind="substitute", confidence=round(min(score, 0.9), 2), reasons=reasons)


class VariantResolution(SModel):
    status: Literal["resolved", "ambiguous", "not_found"]
    variant: Variant | None = None
    options: list[Variant] = Field(default_factory=list)


def resolve_variant(product: Product, hint: str | None = None) -> VariantResolution:
    """Pick the variant the owner meant. One variant: that one. A size hint ("1 kg", "500ml") or a
    label: the variants that match it. Several candidates left: ambiguous (ask, never guess)."""
    variants = product.variants
    if not variants:
        return VariantResolution(status="not_found")
    if hint is None or not hint.strip():
        if len(variants) == 1:
            return VariantResolution(status="resolved", variant=variants[0])
        return VariantResolution(status="ambiguous", options=list(variants))
    wanted = parse_pack(hint)
    if wanted is not None:
        hits = [v for v in variants if same_size(v.pack or parse_pack(v.label), wanted)]
    else:
        lowered = hint.strip().lower()
        hits = [v for v in variants if v.variant_id == hint or lowered in v.label.lower()]
    if len(hits) == 1:
        return VariantResolution(status="resolved", variant=hits[0])
    if not hits:
        return VariantResolution(status="not_found", options=list(variants))
    return VariantResolution(status="ambiguous", options=hits)
