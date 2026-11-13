from __future__ import annotations

from decimal import Decimal

import pytest

from app.shopping.matching import ItemIdentity, match, resolve_variant
from app.shopping.normalize import (
    identity_key,
    normalize_gtin,
    normalize_name,
    parse_pack,
    rupees_to_paise,
    same_size,
    unit_price,
)
from app.shopping.types import PackSize, Product, Variant

from .conftest import NOW


@pytest.mark.parametrize(
    ("label", "quantity", "unit", "count", "total"),
    [
        ("1 kg", "1000", "g", 1, "1000"),
        ("500g", "500", "g", 1, "500"),
        ("200 gm", "200", "g", 1, "200"),
        ("1.5 kg", "1500.0", "g", 1, "1500"),
        ("2 x 500 g", "500", "g", 2, "1000"),
        ("500 g x 2", "500", "g", 2, "1000"),
        ("4 × 1 L", "1000", "ml", 4, "4000"),
        ("750 ml", "750", "ml", 1, "750"),
        ("1 litre", "1000", "ml", 1, "1000"),
        ("6 pcs", "1", "count", 6, "6"),
        ("12 eggs", "1", "count", 12, "12"),
        ("Pack of 3", "1", "count", 3, "3"),
        ("100 g (Pack of 6)", "100", "g", 6, "600"),
        ("250 mg", "0.250", "g", 1, "0.25"),
    ],
)
def test_pack_normalisation_table(label: str, quantity: str, unit: str, count: int, total: str) -> None:
    pack = parse_pack(label)
    assert pack is not None
    assert (pack.quantity, pack.unit, pack.count) == (Decimal(quantity), unit, count)
    assert pack.total == Decimal(total)


@pytest.mark.parametrize("label", ["", None, "Family size", "Large", "0 g"])
def test_unparseable_sizes_are_not_guessed(label: str | None) -> None:
    assert parse_pack(label) is None


def test_multipack_equals_single_pack_of_same_total() -> None:
    assert same_size(parse_pack("2 x 500 g"), parse_pack("1 kg"))
    assert not same_size(parse_pack("1 kg"), parse_pack("1 L"))
    assert not same_size(parse_pack("1 kg"), None)


def test_unit_price_is_exact() -> None:
    assert unit_price(28900, parse_pack("5 kg")) == (Decimal("5.78"), "per 100 g")
    assert unit_price(2900, parse_pack("500 ml")) == (Decimal("58.00"), "per litre")
    assert unit_price(9000, parse_pack("12 eggs")) == (Decimal("7.50"), "per piece")
    assert unit_price(100, None) is None


def test_names_brands_gtins_and_prices() -> None:
    assert normalize_name("Aashirvaad Shudh Chakki Atta, 5 kg", "Aashirvaad") == "shudh chakki atta"
    assert normalize_name("Amul Taaza Toned Milk (500 ml)", "Amul") == "taaza toned milk"
    assert (
        identity_key("Amul", "Amul Taaza Toned Milk 500 ml", parse_pack("500 ml"))
        == "amul|taaza toned milk|500ml"
    )
    assert normalize_gtin("8901030865275") == "08901030865275"
    assert normalize_gtin("8901030865278") is None  # bad check digit
    assert normalize_gtin("abc") is None
    assert rupees_to_paise(289) == 28900
    assert rupees_to_paise(28.9) == 2890
    assert rupees_to_paise("₹1,234.50") == 123450
    assert rupees_to_paise("FREE") is None
    assert rupees_to_paise(True) is None
    assert rupees_to_paise(-1) is None


def _id(name: str, brand: str | None, size: str | None, gtin: str | None = None) -> ItemIdentity:
    return ItemIdentity(name=name, brand=brand, pack=parse_pack(size), gtin=gtin)


def test_exact_match_by_barcode_and_by_brand_name_size() -> None:
    by_gtin = match(
        _id("Atta", "A", "5 kg", "8901030865275"), _id("Whole wheat", "B", "1 kg", "8901030865275")
    )
    assert by_gtin.kind == "exact" and by_gtin.confidence == 1.0

    same = match(_id("Amul Butter 2 x 500 g", "Amul", "2 x 500 g"), _id("AMUL butter", "amul", "1 kg"))
    assert same.kind == "exact" and same.confidence == 0.95


def test_substitutes_carry_reasons_and_never_exact() -> None:
    brand = match(
        _id("Aashirvaad Chakki Atta", "Aashirvaad", "5 kg"), _id("Pillsbury Chakki Atta", "Pillsbury", "5 kg")
    )
    assert brand.kind == "substitute" and "different brand" in brand.reasons and brand.confidence < 0.95

    size = match(_id("Amul Butter", "Amul", "500 g"), _id("Amul Butter", "Amul", "100 g"))
    assert size.kind == "substitute" and any(r.startswith("different size") for r in size.reasons)

    barcode = match(
        _id("Amul Butter", "Amul", "500 g", "8901030865275"), _id("Amul Butter", "Amul", "500 g", "96385074")
    )
    assert barcode.kind == "substitute" and "different barcode" in barcode.reasons

    no_brand = match(_id("Toned milk", None, "1 L"), _id("Toned milk", None, "1 L"))
    assert no_brand.kind == "substitute"  # no brand on either side: never claimed exact

    assert match(_id("Atta", "A", "5 kg"), _id("Dishwash liquid", "B", "500 ml")).kind == "none"


def _product(variants: list[Variant]) -> Product:
    return Product(
        source="t:search", retrieved_at=NOW, provider="t", product_id="p1", name="Atta", variants=variants
    )


def test_variant_resolution() -> None:
    five = Variant(variant_id="v5", label="5 kg", pack=PackSize(quantity=Decimal(5000), unit="g"))
    ten = Variant(variant_id="v10", label="10 kg", pack=PackSize(quantity=Decimal(10000), unit="g"))
    assert resolve_variant(_product([five])).variant == five
    assert resolve_variant(_product([five, ten])).status == "ambiguous"
    assert resolve_variant(_product([five, ten]), "10kg").variant == ten
    assert resolve_variant(_product([five, ten]), "5000 g").variant == five
    assert resolve_variant(_product([five, ten]), "v10").variant == ten
    missing = resolve_variant(_product([five, ten]), "1 kg")
    assert missing.status == "not_found" and len(missing.options) == 2
    assert resolve_variant(_product([])).status == "not_found"
