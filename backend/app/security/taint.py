"""Untrusted-content wrapping (web pages, email, PDFs, MCP results).

Wrapped text is data for the model, never instructions, and never goes in the system role. Using
it marks the turn tainted, which raises approval levels (see `PolicyEngine`).
"""

from __future__ import annotations

import re

_TAG = re.compile(r"<(\s*/?\s*)untrusted", re.IGNORECASE)
_SOURCE_UNSAFE = re.compile(r"[^A-Za-z0-9._:/@ -]")


def wrap_untrusted(content: str, source: str) -> str:
    """Return ``<untrusted source="…">…</untrusted>`` with any nested wrapper tags neutralised,
    so content cannot close the wrapper early and pose as trusted text."""
    safe_source = _SOURCE_UNSAFE.sub("_", source)[:120] or "unknown"
    body = _TAG.sub(lambda match: f"&lt;{match.group(1)}untrusted", content)
    return f'<untrusted source="{safe_source}">\n{body}\n</untrusted>'


def is_wrapped(text: str) -> bool:
    return text.lstrip().startswith("<untrusted source=") and text.rstrip().endswith("</untrusted>")
