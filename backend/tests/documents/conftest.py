"""Document tests load the memory and documents plugins (documents belong to the knowledge category)."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any

import pytest

from app.core.clock import FixedClock
from app.core.types import AgentId, PrivacyMode
from app.documents.service import DocumentService
from app.plugins import PluginRegistry
from app.tools.spec import ToolContext


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("app.memory.plugin", "app.documents.plugin")


@pytest.fixture
def clock() -> FixedClock:
    return FixedClock(datetime.now(UTC).replace(microsecond=0))


@pytest.fixture
def documents(registry: PluginRegistry) -> DocumentService:
    service: DocumentService = registry.service("documents")
    return service


def make_ctx(registry: PluginRegistry, **overrides: Any) -> ToolContext:
    fields: dict[str, Any] = {
        "turn_id": "turn_doc",
        "agent": AgentId.DOCUMENT,
        "conversation_id": "conv_doc",
        "privacy_mode": PrivacyMode.STRICT_PRIVATE,
        "user_initiated": True,
    }
    fields.update(overrides)
    return registry.tool_context(**fields)


def make_pdf(pages: list[str]) -> bytes:
    """A minimal, valid text PDF (one Helvetica line per page) built by hand for tests."""
    objects: list[bytes] = [b"<< /Type /Catalog /Pages 2 0 R >>"]
    kids = " ".join(f"{4 + 2 * i} 0 R" for i in range(len(pages)))
    objects.append(f"<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>".encode())
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i, text in enumerate(pages):
        safe = text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        stream = f"BT /F1 12 Tf 72 720 Td ({safe}) Tj ET".encode()
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {5 + 2 * i} 0 R "
            f"/Resources << /Font << /F1 3 0 R >> >> >>".encode()
        )
        objects.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
    out = bytearray(b"%PDF-1.4\n")
    offsets: list[int] = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


SAMPLE_TEXT = (
    "The Acme warranty lasts for two years from the date of purchase.\n\n"
    "To claim the warranty, contact support with your receipt and the serial number.\n\n"
    "The lease agreement for the flat in Pune runs until March 2027 and the monthly rent is due on the fifth.\n\n"
    "Recipe notes: soak the rajma overnight, pressure cook for six whistles, then simmer with onion and tomato masala."
)
