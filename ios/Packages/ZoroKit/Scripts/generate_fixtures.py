"""Generate JSON fixtures for the ZoroCore Swift mirrors from the real Pydantic contract.

Run from the backend directory:

    cd backend && PYTHONPATH=. uv run --no-sync python ../ios/Packages/ZoroKit/Scripts/generate_fixtures.py

Writes test-only sample data into ios/Packages/ZoroKit/Tests/ZoroCoreTests/Fixtures/:
- enums.json      every StrEnum in app.core.types -> list of raw values
- models.json     every ZModel subclass in app.schemas.* -> {"full": json, "minimal": json}
- turn_events.json every TurnEvent variant (plus one unknown type) as a list
and into Tests/SecurityManagerTests/Fixtures/:
- signature_vector.json an ECDSA P-256 vector made with `cryptography` (cross-language check)
"""

from __future__ import annotations

import base64
import enum
import inspect
import json
import types
import typing
from datetime import UTC, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Literal, get_args, get_origin

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from pydantic import BaseModel

from app.core import types as core_types
from app.schemas import auth, common, data, security, turns
from app.schemas.common import Page, ZModel

OUT = Path(__file__).resolve().parent.parent / "Tests" / "ZoroCoreTests" / "Fixtures"
SECURITY_OUT = Path(__file__).resolve().parent.parent / "Tests" / "SecurityManagerTests" / "Fixtures"
MODULES = [common, auth, security, turns, data]
BASE_TIME = datetime(2026, 11, 12, 9, 30, 15, 123456, tzinfo=UTC)
IST = timezone(timedelta(hours=5, minutes=30))


def sample(annotation: Any, name: str, depth: int) -> Any:
    origin = get_origin(annotation)
    args = get_args(annotation)
    if annotation is Any:
        return {"nested": {"k": [1, 2.5, "x", True, None]}}
    if origin in (typing.Union, types.UnionType):
        non_none = [a for a in args if a is not type(None)]
        return sample(non_none[0], name, depth)
    if origin is typing.Annotated:
        return sample(args[0], name, depth)
    if origin is Literal:
        return args[-1]
    if origin is list:
        return [sample(args[0], name, depth + 1)]
    if origin is dict:
        return {"selected_product_ref": "prod_1", "count": 2, "nested_key": {"inner_key": [1, "a"]}}
    if inspect.isclass(annotation):
        if issubclass(annotation, enum.Enum):
            members = list(annotation)
            return members[-1]
        if issubclass(annotation, BaseModel):
            return build(annotation, full=True, depth=depth + 1)
        if annotation is bool:
            return True
        if annotation is int:
            return 42
        if annotation is float:
            return 1.0 if name in {"confidence", "speaking_rate", "error_rate"} else 12.5
        if annotation is Decimal:
            return Decimal("1234.50")
        if annotation is datetime:
            return BASE_TIME if depth % 2 == 0 else BASE_TIME.replace(microsecond=0).astimezone(IST)
        if annotation is str:
            return f"{name}-value"
    if str(annotation) == "AwareDatetime" or getattr(annotation, "__name__", "") == "AwareDatetime":
        return BASE_TIME if depth % 2 == 0 else BASE_TIME.replace(microsecond=0).astimezone(IST)
    raise TypeError(f"no sample for {annotation!r} ({name})")


def build(model: type[BaseModel], *, full: bool, depth: int = 0) -> BaseModel:
    values: dict[str, Any] = {}
    for fname, field in model.model_fields.items():
        if not full and not field.is_required():
            continue
        annotation = field.annotation
        if fname == "type" and get_origin(annotation) is Literal:
            continue
        values[fname] = OVERRIDES.get((model.__name__, fname)) or sample(annotation, fname, depth)
    return model(**values)


# Fields typed `str` in Python whose server-accepted values are a closed set (mirrored as Swift enums).
OVERRIDES: dict[tuple[str, str], Any] = {("SignedProof", "key"): "auth"}


def zmodels() -> list[type[BaseModel]]:
    found: list[type[BaseModel]] = []
    for mod in MODULES:
        for _, obj in inspect.getmembers(mod, inspect.isclass):
            if obj.__module__ != mod.__name__ or obj in (ZModel, Page):
                continue
            if issubclass(obj, ZModel) and not getattr(obj, "__pydantic_generic_metadata__", {}).get("origin"):
                found.append(obj)
    return sorted(found, key=lambda c: c.__name__)


def dump(m: BaseModel, *, minimal: bool) -> Any:
    return json.loads(m.model_dump_json(exclude_unset=minimal))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    enums = {
        name: [m.value for m in obj]
        for name, obj in inspect.getmembers(core_types, inspect.isclass)
        if issubclass(obj, enum.Enum) and obj.__module__ == core_types.__name__
    }
    models: dict[str, Any] = {}
    for cls in zmodels():
        models[cls.__name__] = {"full": dump(build(cls, full=True), minimal=False), "minimal": dump(build(cls, full=False), minimal=True)}
    for item in (data.MemoryRecord, data.ConversationSummary):
        page = Page[item](items=[build(item, full=True)], next_cursor="cursor-2")
        models[f"Page[{item.__name__}]"] = {"full": dump(page, minimal=False), "minimal": {"items": []}}
    # money edge cases: exact decimal strings must survive
    models["Money"]["extra"] = [{"amount": "0.10", "currency": "INR"}, {"amount": "-99999999999.99"}, {"amount": "1E+2"}]

    variants = get_args(get_args(turns.TurnEvent)[0])
    events = [dump(build(v, full=True), minimal=False) for v in variants]
    events.append({"type": "future_event_kind", "some_field": 1})

    key = ec.generate_private_key(ec.SECP256R1())
    message = "zoro-auth-v1|dev_test|nonce_test"
    sig = key.sign(message.encode(), ec.ECDSA(hashes.SHA256()))
    pub = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    vector = {"message": message, "public_key_b64": base64.b64encode(pub).decode(), "signature_b64": base64.b64encode(sig).decode()}

    for fname, payload in (("enums.json", enums), ("models.json", models), ("turn_events.json", events)):
        (OUT / fname).write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n")
    SECURITY_OUT.mkdir(parents=True, exist_ok=True)
    (SECURITY_OUT / "signature_vector.json").write_text(json.dumps(vector, indent=1, sort_keys=True) + "\n")
    print(f"enums={len(enums)} models={len(models)} events={len(events)} -> {OUT}")


if __name__ == "__main__":
    main()
