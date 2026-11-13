"""Compare shortlisted products using only retrieved specifications.

A cell exists only where the source gave a value. Seller, warranty and returns rows appear only when
some source provided them. No winner is declared; the only computed fact is the lowest listed price
among entries that have one.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Sequence
from datetime import datetime
from decimal import Decimal
from typing import Protocol

from pydantic import BaseModel, Field


class SpecSource(Protocol):
    """What a shortlist entry provides (see `app.shopping.shortlist.ShortlistEntry`)."""

    entry_id: str
    provider: str
    name: str
    brand: str | None
    url: str | None
    price: Decimal | None
    attributes: dict[str, str]
    source: str
    retrieved_at: datetime


class Cell(BaseModel):
    value: str
    source: str
    retrieved_at: datetime


class Row(BaseModel):
    attribute: str
    cells: dict[str, Cell | None]  # entry_id -> value, None = not provided by the source
    differs: bool


class ComparedProduct(BaseModel):
    entry_id: str
    provider: str
    name: str
    brand: str | None
    url: str | None
    source: str
    retrieved_at: datetime


class ProductComparison(BaseModel):
    products: list[ComparedProduct]
    rows: list[Row]
    lowest_price_entry: str | None = None
    notes: list[str] = Field(default_factory=list)


_POLICY_KEYS = ("seller", "warranty", "returns", "return_policy")


def compare_products(entries: Sequence[SpecSource]) -> ProductComparison:
    products = [
        ComparedProduct(
            entry_id=e.entry_id,
            provider=e.provider,
            name=e.name,
            brand=e.brand,
            url=e.url,
            source=e.source,
            retrieved_at=e.retrieved_at,
        )
        for e in entries
    ]
    rows: list[Row] = []

    def add_row(attribute: str, values: dict[str, str | None]) -> None:
        cells = {
            e.entry_id: Cell(value=v, source=e.source, retrieved_at=e.retrieved_at)
            if (v := values.get(e.entry_id))
            else None
            for e in entries
        }
        present = {c.value.strip().lower() for c in cells.values() if c is not None}
        rows.append(Row(attribute=attribute, cells=cells, differs=len(present) > 1 or None in cells.values()))

    prices = {e.entry_id: e.price for e in entries if e.price is not None}
    if prices:
        add_row("price", {k: f"{v:.2f}" for k, v in prices.items()})
    if any(e.brand for e in entries):
        add_row("brand", {e.entry_id: e.brand for e in entries})
    counts = Counter(k for e in entries for k in e.attributes)
    for key, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        add_row(key, {e.entry_id: e.attributes.get(key) for e in entries})
    notes = []
    missing_policy = [k for k in _POLICY_KEYS[:3] if k not in counts]
    if missing_policy:
        notes.append(f"Not provided by any source: {', '.join(missing_policy)}.")
    lowest = None
    if prices:
        low = min(prices.values())
        winners = [k for k, v in prices.items() if v == low]
        lowest = winners[0] if len(winners) == 1 else None
    return ProductComparison(products=products, rows=rows, lowest_price_entry=lowest, notes=notes)
