"""Upload checks, content sniffing, text extraction (pdfplumber) and chunking. No I/O beyond the bytes."""

from __future__ import annotations

import asyncio
import io
import re
from dataclasses import dataclass

from app.core.errors import ZoroError

MAX_BYTES = 15 * 1024 * 1024
MAX_PAGES = 500
MAX_CHUNKS = 4000
CHUNK_CHARS = 900
OVERLAP_CHARS = 120
PDF_TIMEOUT_S = 45.0

_EXTENSIONS = {"pdf": "pdf", "txt": "txt", "text": "txt", "md": "md", "markdown": "md", "csv": "csv"}
MEDIA_TYPES = {"pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown", "csv": "text/csv"}


class DocumentError(ZoroError):
    code = "document_error"
    status = 422


class DocumentTooLarge(DocumentError):
    code = "document_too_large"
    status = 413
    default_message = "This file is larger than ZORO accepts."


class LengthRequired(DocumentError):
    code = "content_length_required"
    status = 411
    default_message = "Send the upload with a Content-Length header."


class UnsupportedDocument(DocumentError):
    code = "document_unsupported"
    status = 415
    default_message = "Only PDF, TXT, MD and CSV files are supported."


class MalformedDocument(DocumentError):
    code = "document_malformed"
    default_message = "This file could not be read. It may be damaged or password protected."


class EmptyDocument(DocumentError):
    code = "document_empty"
    default_message = (
        "No text could be extracted. Scanned or image-only files need OCR, which is not available."
    )


class KnowledgeDisabled(DocumentError):
    code = "knowledge_memory_disabled"
    status = 409
    default_message = "The knowledge memory category is switched off. Turn it on in Memory settings first."


@dataclass(frozen=True)
class Chunk:
    text: str
    page: int | None


@dataclass(frozen=True)
class Extracted:
    kind: str
    pages: list[tuple[int | None, str]]
    page_count: int | None


def clean_title(filename: str) -> str:
    name = re.split(r"[\\/]", filename.strip())[-1]
    name = "".join(ch for ch in name if ch.isprintable())[:200].strip()
    return name or "document"


def sniff(filename: str, data: bytes, *, max_bytes: int = MAX_BYTES) -> str:
    """The document kind, decided by content and checked against the extension. Raises
    `DocumentTooLarge`, `MalformedDocument` (empty file) or `UnsupportedDocument` (type mismatch)."""
    if len(data) > max_bytes:
        raise DocumentTooLarge(f"This file is larger than the {max_bytes // (1024 * 1024)} MB limit.")
    if not data.strip():
        raise MalformedDocument("The file is empty.")
    extension = _EXTENSIONS.get(filename.rsplit(".", 1)[-1].lower()) if "." in filename else None
    if extension is None:
        raise UnsupportedDocument()
    is_pdf = b"%PDF-" in data[:1024]
    if extension == "pdf":
        if not is_pdf:
            raise UnsupportedDocument("This file is named .pdf but is not a PDF.")
        return "pdf"
    if is_pdf:
        raise UnsupportedDocument("This file is a PDF but is named like a text file.")
    decode_text(data)  # binary content with a text extension is refused here
    return extension


def decode_text(data: bytes) -> str:
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        try:
            return data.decode("utf-16")
        except UnicodeDecodeError as exc:
            raise MalformedDocument() from exc
    if b"\x00" in data[:8192]:
        raise UnsupportedDocument("This file looks binary, not text.")
    for encoding in ("utf-8-sig", "cp1252"):
        try:
            text = data.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:
        raise UnsupportedDocument("This file is not readable text.")
    sample = text[:8192]
    control = sum(1 for ch in sample if ord(ch) < 32 and ch not in "\n\r\t\f")
    if sample and control / len(sample) > 0.05:
        raise UnsupportedDocument("This file looks binary, not text.")
    return text


def _extract_pdf(data: bytes) -> Extracted:
    import pdfplumber

    try:
        with pdfplumber.open(io.BytesIO(data)) as pdf:
            count = len(pdf.pages)
            if count > MAX_PAGES:
                raise DocumentTooLarge(f"This PDF has {count} pages; the limit is {MAX_PAGES}.")
            pages: list[tuple[int | None, str]] = [
                (index + 1, page.extract_text() or "") for index, page in enumerate(pdf.pages)
            ]
    except ZoroError:
        raise
    except Exception as exc:  # pdfminer raises many types for damaged or encrypted files
        raise MalformedDocument() from exc
    return Extracted("pdf", pages, count)


async def extract(kind: str, data: bytes) -> Extracted:
    if kind == "pdf":
        try:
            return await asyncio.wait_for(asyncio.to_thread(_extract_pdf, data), timeout=PDF_TIMEOUT_S)
        except TimeoutError as exc:
            raise MalformedDocument("Reading this PDF took too long.") from exc
    return Extracted(kind, [(None, decode_text(data))], None)


# ---------------------------------------------------------------- chunking


def _windows(text: str, size: int, overlap: int) -> list[str]:
    pieces: list[str] = []
    start = 0
    while start < len(text):
        end = min(len(text), start + size)
        if end < len(text):
            cut = text.rfind(" ", start + size // 2, end)
            end = cut if cut > start else end
        pieces.append(text[start:end].strip())
        if end >= len(text):
            break
        start = max(end - overlap, start + 1)
    return [p for p in pieces if p]


def _chunk_prose(page: int | None, text: str, size: int, overlap: int) -> list[Chunk]:
    out: list[Chunk] = []
    buffer = ""
    for paragraph in re.split(r"\n\s*\n", text):
        para = " ".join(paragraph.split())
        if not para:
            continue
        if len(para) > size:
            if buffer:
                out.append(Chunk(buffer, page))
                buffer = ""
            out.extend(Chunk(piece, page) for piece in _windows(para, size, overlap))
        elif buffer and len(buffer) + 1 + len(para) > size:
            out.append(Chunk(buffer, page))
            buffer = para
        else:
            buffer = f"{buffer} {para}" if buffer else para
    if buffer:
        out.append(Chunk(buffer, page))
    return out


def _chunk_csv(text: str, size: int) -> list[Chunk]:
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        return []
    header, rows = lines[0], lines[1:]
    out: list[Chunk] = []
    current: list[str] = []
    length = len(header)
    for row in rows:
        row = row[: size - len(header) - 1] if len(row) + len(header) + 1 > size else row
        if current and length + len(row) + 1 > size:
            out.append(Chunk("\n".join([header, *current]), None))
            current, length = [], len(header)
        current.append(row)
        length += len(row) + 1
    if current or not rows:
        out.append(Chunk("\n".join([header, *current]), None))
    return out


def chunk(extracted: Extracted, *, size: int = CHUNK_CHARS, overlap: int = OVERLAP_CHARS) -> list[Chunk]:
    """Paragraph-aware chunks of about `size` characters (CSV: row groups that repeat the header row)."""
    if extracted.kind == "csv":
        chunks = _chunk_csv(extracted.pages[0][1], size)
    else:
        chunks = [c for page, text in extracted.pages for c in _chunk_prose(page, text, size, overlap)]
    if len(chunks) > MAX_CHUNKS:
        raise DocumentTooLarge(f"This file would need {len(chunks)} passages; the limit is {MAX_CHUNKS}.")
    return chunks
