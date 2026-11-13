"""Argument templates for routine steps.

`{{params.name}}`, `{{now.date}}` / `{{now.time}}` / `{{now.iso}}` and `{{steps.N.path}}` (a field of the
Nth earlier step's result) are replaced when a step runs. A value that is exactly one placeholder keeps
its type; inside longer text it becomes text. An unknown or missing name stops the run instead of
sending a half-filled argument.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

_PLACEHOLDER = re.compile(r"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}")
_ROOTS = ("params", "now", "steps")
MAX_ARGS_BYTES = 8192


class TemplateError(ValueError):
    pass


def placeholders(value: Any) -> list[str]:
    """Every placeholder name in a nested value (for validation at save time)."""
    if isinstance(value, str):
        return _PLACEHOLDER.findall(value)
    if isinstance(value, dict):
        return [p for v in value.values() for p in placeholders(v)]
    if isinstance(value, list):
        return [p for v in value for p in placeholders(v)]
    return []


def check_syntax(args: dict[str, Any], step_index: int) -> None:
    """Refuse templates that can never resolve: unknown roots, forward references, oversize arguments."""
    if len(json.dumps(args, default=str)) > MAX_ARGS_BYTES:
        raise TemplateError(f"arguments are larger than {MAX_ARGS_BYTES} bytes")
    if "{{" in json.dumps(args) and len(placeholders(args)) != json.dumps(args).count("{{"):
        raise TemplateError("a placeholder is malformed; use {{params.x}}, {{now.date}} or {{steps.N.field}}")
    for name in placeholders(args):
        root, _, rest = name.partition(".")
        if root not in _ROOTS or not rest:
            raise TemplateError(f"unknown placeholder {{{{{name}}}}}")
        if root == "now" and rest not in ("date", "time", "iso"):
            raise TemplateError(f"unknown placeholder {{{{{name}}}}}")
        if root == "steps":
            index, _, path = rest.partition(".")
            if not index.isdigit() or not path or int(index) >= step_index:
                raise TemplateError(f"{{{{{name}}}}} must refer to an earlier step's field")


def _lookup(name: str, context: dict[str, Any]) -> Any:
    node: Any = context
    for part in name.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            raise TemplateError(f"{{{{{name}}}}} has no value")
    return node


def build_context(params: dict[str, Any], results: list[Any], now: datetime, tz: ZoneInfo) -> dict[str, Any]:
    local = now.astimezone(tz)
    return {
        "params": params,
        "steps": results,
        "now": {
            "date": local.date().isoformat(),
            "time": local.strftime("%H:%M"),
            "iso": local.isoformat(timespec="seconds"),
        },
    }


def render(value: Any, context: dict[str, Any]) -> Any:
    if isinstance(value, str):
        whole = _PLACEHOLDER.fullmatch(value.strip())
        if whole:
            return _lookup(whole.group(1), context)
        return _PLACEHOLDER.sub(lambda m: str(_lookup(m.group(1), context)), value)
    if isinstance(value, dict):
        return {k: render(v, context) for k, v in value.items()}
    if isinstance(value, list):
        return [render(v, context) for v in value]
    return value
