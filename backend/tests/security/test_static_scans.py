"""Source and metadata scans: rule 7 (no model names in code), rule 5 (no secrets), rule 2 (money)."""

from __future__ import annotations

import re
import types
import typing
from collections.abc import Iterator
from pathlib import Path

import pytest
import yaml
from pydantic import BaseModel
from sqlalchemy import BigInteger, Float, Integer, Numeric

from app.db.base import Base
from app.db.discovery import import_models

BACKEND = Path(__file__).resolve().parents[2]
REPO = BACKEND.parent
APP = BACKEND / "app"
THIS_FILE = Path(__file__).resolve()

# ------------------------------------------------------------------------------ rule 7


def _model_identifiers() -> set[str]:
    raw = yaml.safe_load((REPO / "config" / "models.yaml").read_text(encoding="utf-8"))
    names: set[str] = set()
    for model in raw.get("models", []):
        names.add(str(model["id"]))
        if model.get("model_name"):
            names.add(str(model["model_name"]))
    return names


def test_models_yaml_has_models() -> None:
    assert len(_model_identifiers()) >= 5


def test_no_model_identifier_appears_in_app_source() -> None:
    identifiers = _model_identifiers()
    hits: list[str] = []
    for path in sorted(APP.rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        for ident in identifiers:
            # whole-token match, so "qwen-plus" does not match inside "qwen-plus-2" and vice versa
            if re.search(rf"(?<![\w.:/-]){re.escape(ident)}(?![\w.:/-])", text):
                hits.append(f"{path.relative_to(BACKEND)}: {ident}")
    assert hits == [], "model identifiers belong in config/models.yaml only:\n" + "\n".join(hits)


# ------------------------------------------------------------------------------ rule 5

_SKIP_DIRS = {
    ".venv", ".git", ".local", ".cache", "__pycache__", ".mypy_cache", ".ruff_cache", ".pytest_cache",
    ".build", ".swiftpm", "DerivedData", "node_modules",
}  # fmt: skip
_SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".pdf", ".xlsx", ".lock", ".db", ".sqlite", ".pyc", ".ico", ".zip"}
_PEM = "-----BEGIN " + r"(?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"
_SECRET_PATTERNS: dict[str, re.Pattern[str]] = {
    "private key block": re.compile(_PEM),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "Google API key": re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"),
    "OpenAI-style key": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b"),
    "xAI key": re.compile(r"\bxai-[A-Za-z0-9]{32,}\b"),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b"),
    "Slack token": re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{20,}\b"),
    "Groq key": re.compile(r"\bgsk_[A-Za-z0-9]{40,}\b"),
    "JWT": re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{20,}\b"),
    "assigned secret": re.compile(
        r"(?i)\b[A-Z_]*(?:API_KEY|SECRET|TOKEN|PASSWORD)[A-Z_]*\s*[=:]\s*[\"']?(?=[A-Za-z0-9+/_-]*\d)"
        r"(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{24,}[\"']?\s*$",
        re.M,
    ),
}


#: Deliberate, obviously fake fixtures that exercise redaction (each reviewed by hand).
_ALLOWED_HITS = {
    # unsigned sample JWT whose signature segment is base64 of "signature-value"
    ("backend/tests/kernel/test_core.py", "JWT"),
    # sample sensitive string ("PAN-ABCDE1234F-salary-98765") used to test at-rest sealing
    ("ios/Packages/ZoroKit/Tests/ConversationManagerTests/ConversationStoreTests.swift", "assigned secret"),
}


def _repo_files() -> Iterator[Path]:
    stack = [REPO]
    while stack:
        current = stack.pop()
        for child in current.iterdir():
            if child.is_dir():
                if child.name not in _SKIP_DIRS and not child.is_symlink():
                    stack.append(child)
            elif child.suffix.lower() not in _SKIP_SUFFIXES and child.resolve() != THIS_FILE:
                yield child


def test_no_secret_looking_strings_in_the_repository() -> None:
    hits: list[str] = []
    scanned = 0
    for path in _repo_files():
        if path.name == ".env":  # git-ignored local secrets file, never shipped
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        for label, pattern in _SECRET_PATTERNS.items():
            for match in pattern.finditer(text):
                if (str(path.relative_to(REPO)), label) in _ALLOWED_HITS:
                    continue
                line = text.count("\n", 0, match.start()) + 1
                hits.append(f"{path.relative_to(REPO)}:{line}: {label}")
    assert scanned > 100
    assert hits == [], "secret-looking strings found:\n" + "\n".join(hits)


def test_secret_patterns_catch_real_shapes() -> None:
    samples = {
        "Google API key": "AIza" + "S" * 35,
        "AWS access key": "AKIA" + "ABCDEFGHIJKLMNOP",
        "OpenAI-style key": "sk-" + "a1" * 20,
        "private key block": "-----BEGIN " + "PRIVATE KEY-----",
        "assigned secret": "GEMINI_API_KEY=" + "ab12" * 8,
    }
    for label, sample in samples.items():
        assert _SECRET_PATTERNS[label].search(sample), label
    assert not _SECRET_PATTERNS["assigned secret"].search("GEMINI_API_KEY=")


# ------------------------------------------------------------------------------ rule 2

_MONEY_WORD = re.compile(
    r"(^|_)(amount|price|paise|balance|fee|fees|charge|charges|cost|mrp|pnl|budget|invested|rupees|inr|usd)(_|$)"
)
_NOT_A_VALUE = re.compile(r"(_at|_as_of|_source|_currency|_date|_check|_count|_id|_kind)$")


def _money_column(name: str) -> bool:
    return bool(_MONEY_WORD.search(name)) and not _NOT_A_VALUE.search(name)


@pytest.fixture(scope="module")
def metadata_tables() -> dict[str, typing.Any]:
    import_models()
    return dict(Base.metadata.tables)


def test_money_columns_are_integer_minor_units(metadata_tables: dict[str, typing.Any]) -> None:
    bad: list[str] = []
    money_columns = 0
    for table in metadata_tables.values():
        for column in table.columns:
            name = column.name
            if isinstance(column.type, Float | Numeric) and _money_column(name):
                bad.append(f"{table.name}.{name}: {column.type} (float/numeric money)")
                continue
            if not _money_column(name):
                continue
            money_columns += 1
            if not isinstance(column.type, Integer | BigInteger):
                bad.append(f"{table.name}.{name}: {column.type} (must be integer minor units)")
            elif not (name.endswith("_paise") or name.endswith("_micro_usd")):
                bad.append(f"{table.name}.{name}: money column must be named *_paise (or *_micro_usd)")
    assert money_columns >= 5, "expected the finance, investment and shopping money columns"
    assert bad == [], "\n".join(bad)


def _contains_float(annotation: typing.Any) -> bool:
    if annotation is float:
        return True
    origin = typing.get_origin(annotation)
    if origin is typing.Annotated:
        return _contains_float(typing.get_args(annotation)[0])
    if origin in (typing.Union, types.UnionType) or origin in (list, tuple, set, frozenset, dict):
        return any(_contains_float(arg) for arg in typing.get_args(annotation) if arg is not Ellipsis)
    return False


def _app_models() -> Iterator[type[BaseModel]]:
    seen: set[type[BaseModel]] = set()
    stack = list(BaseModel.__subclasses__())
    while stack:
        cls = stack.pop()
        stack.extend(cls.__subclasses__())
        if cls in seen or not cls.__module__.startswith("app."):
            continue
        seen.add(cls)
        yield cls


def test_no_float_money_in_pydantic_models(app: typing.Any) -> None:  # `app` loads every plugin
    bad: list[str] = []
    checked = 0
    for model in _app_models():
        for name, field in model.model_fields.items():
            checked += 1
            if (
                _MONEY_WORD.search(name)
                and not _NOT_A_VALUE.search(name)
                and _contains_float(field.annotation)
            ):
                bad.append(f"{model.__module__}.{model.__name__}.{name}: {field.annotation}")
    assert checked > 500
    assert bad == [], "money must be Decimal (decimal strings in JSON), never float:\n" + "\n".join(bad)


def test_float_detector() -> None:
    from decimal import Decimal

    assert _contains_float(float | None)
    assert _contains_float(typing.Annotated[float, "x"])
    assert _contains_float(list[float])
    assert not _contains_float(Decimal | None)
    assert not _contains_float(typing.Annotated[Decimal, "_no_float"])
