"""DocumentService (registered as service ``documents``): ingest, private retrieval, delete.

An upload is stored through the kernel ObjectStore, its text is extracted and chunked, and every chunk
is embedded into the knowledge category. Chunk text and (above `personal`) the stored file are sealed.
Deleting a document removes the object, the chunks and their vectors.
"""

from __future__ import annotations

import hashlib
import logging
from collections.abc import Callable
from typing import Any

from sqlalchemy import delete, select

from app.core.clock import Clock
from app.core.errors import NotFound
from app.core.ids import new_id
from app.core.objects import ObjectStore
from app.core.types import DataClass, MemoryCategory, PrivacyMode
from app.db.session import SessionFactory
from app.db.vector import vector_search
from app.documents import extract as ex
from app.documents.models import DocumentChunkRow, DocumentRow
from app.documents.schemas import DocumentHit, DocumentInfo, StoredObjectInfo
from app.memory.access import ALL_BUT_SECRET, allowed_classes
from app.memory.classify import detect_sensitivity, keyword_score, max_sensitivity, tokens
from app.memory.embedding import embed_texts, query_vectors
from app.schemas.common import Page
from app.security.crypto import FieldCipher

log = logging.getLogger(__name__)

EMBED_BATCH = 64
EXCERPT_CHARS = 1000


def _sealed(sensitivity: DataClass) -> bool:
    return sensitivity.rank > DataClass.PERSONAL.rank


class DocumentService:
    def __init__(
        self,
        session_factory: SessionFactory,
        cipher: FieldCipher,
        clock: Clock,
        objects: ObjectStore,
        *,
        memory: Callable[[], Any | None] = lambda: None,
        gateway: Callable[[], Any | None] = lambda: None,
        privacy: Callable[[], Any | None] = lambda: None,
        audit: Any | None = None,
        max_bytes: int = ex.MAX_BYTES,
    ) -> None:
        self._sf = session_factory
        self._cipher = cipher
        self._clock = clock
        self._objects = objects
        self._memory = memory
        self._gateway = gateway
        self._privacy = privacy
        self._audit = audit
        self.max_bytes = max_bytes

    # ------------------------------------------------------------ helpers

    async def knowledge_enabled(self) -> bool:
        memory = self._memory()
        return True if memory is None else bool(await memory.prefs.is_enabled(MemoryCategory.KNOWLEDGE))

    async def current_mode(self) -> PrivacyMode:
        privacy = self._privacy()
        return PrivacyMode.STRICT_PRIVATE if privacy is None else await privacy.get_mode()

    async def _audit_event(self, action: str, actor: str, detail: str, classes: list[DataClass]) -> None:
        if self._audit is not None:
            await self._audit.append(actor=actor, action=action, data_classes=classes, detail=detail)

    @staticmethod
    def _info(row: DocumentRow) -> DocumentInfo:
        return DocumentInfo(
            id=row.id,
            title=row.title,
            kind=row.kind,
            size_bytes=row.size_bytes,
            sha256=row.sha256,
            sensitivity=DataClass(row.sensitivity),
            page_count=row.page_count,
            chunk_count=row.chunk_count,
            created_at=row.created_at,
        )

    def _chunk_text(self, row: DocumentChunkRow) -> str:
        if row.text_enc is not None:
            return self._cipher.decrypt_str(row.text_enc, aad=f"doc_chunk|{row.id}")
        return row.text_plain or ""

    # ------------------------------------------------------------ upload

    async def upload(
        self,
        filename: str,
        data: bytes,
        *,
        sensitivity: DataClass = DataClass.PERSONAL,
        gateway: Any | None = None,
        mode: PrivacyMode | None = None,
        actor: str = "system",
    ) -> tuple[DocumentInfo, bool]:
        """Returns `(document, created)`. The same bytes uploaded twice return the existing document."""
        title = ex.clean_title(filename)
        kind = ex.sniff(title, data, max_bytes=self.max_bytes)
        digest = hashlib.sha256(data).hexdigest()
        async with self._sf() as session:
            existing = (
                await session.execute(select(DocumentRow).where(DocumentRow.sha256 == digest))
            ).scalar_one_or_none()
            if existing is not None:
                return self._info(existing), False
        if not await self.knowledge_enabled():
            raise ex.KnowledgeDisabled()
        extracted = await ex.extract(kind, data)
        chunks = ex.chunk(extracted)
        if not chunks:
            raise ex.EmptyDocument()
        sample = " ".join(c.text for c in chunks[:30])[:20000]
        detected = detect_sensitivity(sample)
        sens = max_sensitivity(sensitivity, DataClass.SENSITIVE if detected is DataClass.SECRET else detected)
        if sens is DataClass.SECRET:
            sens = DataClass.SENSITIVE

        mode = mode or await self.current_mode()
        gw = gateway if gateway is not None else self._gateway()
        embedded_model = ""
        vectors: list[list[float]] = []
        for start in range(0, len(chunks), EMBED_BATCH):
            batch = await embed_texts(
                gw, [c.text for c in chunks[start : start + EMBED_BATCH]], frozenset({sens}), mode
            )
            vectors.extend(batch.vectors)
            embedded_model = batch.model  # one model per upload in practice; stored per chunk below
        models = [embedded_model] * len(chunks)

        doc_id = new_id("doc")
        key = f"documents/{doc_id}/original.{kind}"
        payload = self._cipher.encrypt(data, aad=f"doc_object|{doc_id}").encode() if _sealed(sens) else data
        await self._objects.put(key, payload, content_type=ex.MEDIA_TYPES[kind])
        now = self._clock.now()
        try:
            async with self._sf() as session:
                row = DocumentRow(
                    id=doc_id, title=title, kind=kind, size_bytes=len(data), sha256=digest, object_key=key,
                    sensitivity=sens.value, page_count=extracted.page_count, chunk_count=len(chunks), created_at=now,
                )  # fmt: skip
                session.add(row)
                for index, (piece, vector, model) in enumerate(zip(chunks, vectors, models, strict=True)):
                    chunk_id = new_id("chk")
                    chunk_row = DocumentChunkRow(
                        id=chunk_id, document_id=doc_id, idx=index, page=piece.page, sensitivity=sens.value,
                        embedding=vector, embed_model=model,
                    )  # fmt: skip
                    if _sealed(sens):
                        chunk_row.text_enc = self._cipher.encrypt(piece.text, aad=f"doc_chunk|{chunk_id}")
                    else:
                        chunk_row.text_plain = piece.text
                    session.add(chunk_row)
                await session.commit()
                info = self._info(row)
        except BaseException:
            await self._objects.delete(key)  # no orphan file when the database write fails
            raise
        await self._audit_event(
            "document.upload", actor, f"id={doc_id} kind={kind} chunks={len(chunks)}", [sens]
        )
        return info, True

    # ------------------------------------------------------------ read

    async def get(self, document_id: str) -> DocumentInfo:
        async with self._sf() as session:
            row = await session.get(DocumentRow, document_id)
            if row is None:
                raise NotFound("No such document.", code="document_not_found")
            return self._info(row)

    async def list_documents(self, *, cursor: str | None = None, limit: int = 50) -> Page[DocumentInfo]:
        offset = int(cursor) if cursor and cursor.isdigit() else 0
        stmt = (
            select(DocumentRow)
            .order_by(DocumentRow.created_at.desc(), DocumentRow.id.desc())
            .offset(offset)
            .limit(limit + 1)
        )
        async with self._sf() as session:
            rows = list((await session.execute(stmt)).scalars())
        return Page[DocumentInfo](
            items=[self._info(r) for r in rows[:limit]],
            next_cursor=str(offset + limit) if len(rows) > limit else None,
        )

    async def read_original(self, document_id: str) -> tuple[bytes, str, str]:
        """`(bytes, media type, title)` of the stored file (opened when it was sealed)."""
        async with self._sf() as session:
            row = await session.get(DocumentRow, document_id)
            if row is None:
                raise NotFound("No such document.", code="document_not_found")
            key, sens, kind, title = row.object_key, DataClass(row.sensitivity), row.kind, row.title
        raw = await self._objects.get(key)
        if _sealed(sens):
            raw = self._cipher.decrypt(raw.decode(), aad=f"doc_object|{document_id}")
        return raw, ex.MEDIA_TYPES[kind], title

    async def search(
        self,
        query: str,
        *,
        limit: int = 5,
        allowed: frozenset[DataClass] | None = None,
        gateway: Any | None = None,
        mode: PrivacyMode | None = None,
        min_score: float = 0.2,
        enforce_category: bool = True,
    ) -> list[DocumentHit]:
        """Hybrid vector + keyword search over chunks. Empty when the knowledge category is off."""
        query = query.strip()
        if not query or limit <= 0 or (enforce_category and not await self.knowledge_enabled()):
            return []
        mode = mode or await self.current_mode()
        classes = allowed if allowed is not None else ALL_BUT_SECRET
        q_tokens = tokens(query)
        vectors = await query_vectors(
            gateway if gateway is not None else self._gateway(), query, frozenset({DataClass.PERSONAL}), mode
        )
        where = [DocumentChunkRow.sensitivity.in_([c.value for c in classes])]
        found: dict[str, tuple[DocumentChunkRow, float, float]] = {}
        async with self._sf() as session:
            for model, vector in vectors.items():
                for row, cosine in await vector_search(
                    session, DocumentChunkRow, DocumentChunkRow.embedding, vector, limit=limit * 4,
                    where=[*where, DocumentChunkRow.embed_model == model],
                ):  # fmt: skip
                    found[row.id] = (row, max(cosine, found.get(row.id, (row, 0.0, 0.0))[1]), 0.0)
            for row in (await session.execute(select(DocumentChunkRow).where(*where).limit(5000))).scalars():
                kw = keyword_score(q_tokens, self._chunk_text(row))
                if kw > 0 or row.id in found:
                    found[row.id] = (row, found.get(row.id, (row, 0.0, 0.0))[1], kw)
            scored = sorted(
                ((row, 0.75 * max(cos, 0.0) + 0.25 * kw) for row, cos, kw in found.values()),
                key=lambda pair: -pair[1],
            )
            scored = [pair for pair in scored if pair[1] >= min_score][:limit]
            titles = {
                d.id: d.title
                for d in (
                    await session.execute(
                        select(DocumentRow).where(DocumentRow.id.in_({r.document_id for r, _ in scored}))
                    )
                ).scalars()
            }
            return [
                DocumentHit(
                    document_id=row.document_id,
                    title=titles.get(row.document_id, ""),
                    chunk_index=row.idx,
                    page=row.page,
                    text=self._chunk_text(row)[:EXCERPT_CHARS],
                    score=round(score, 4),
                    sensitivity=DataClass(row.sensitivity),
                    source=f"document:{row.document_id}",
                )
                for row, score in scored
            ]

    async def allowed_for(self, mode: PrivacyMode) -> frozenset[DataClass]:
        return await allowed_classes(self._privacy(), mode)

    # ------------------------------------------------------------ delete

    async def delete(self, document_id: str, *, actor: str = "system") -> bool:
        """Remove the stored object, every chunk and every vector, then the document row."""
        async with self._sf() as session:
            row = await session.get(DocumentRow, document_id)
            if row is None:
                return False
            key, sens = row.object_key, DataClass(row.sensitivity)
        await self._objects.delete(key)
        async with self._sf() as session:
            await session.execute(delete(DocumentChunkRow).where(DocumentChunkRow.document_id == document_id))
            await session.execute(delete(DocumentRow).where(DocumentRow.id == document_id))
            await session.commit()
        await self._audit_event("document.delete", actor, f"id={document_id}", [sens])
        return True

    async def purge_all(self) -> int:
        """Delete every document (used when the knowledge category is deleted)."""
        async with self._sf() as session:
            ids = list((await session.execute(select(DocumentRow.id))).scalars())
        for document_id in ids:
            await self.delete(document_id, actor="memory.delete_category")
        return len(ids)

    async def export_rows(self) -> list[dict[str, Any]]:
        async with self._sf() as session:
            rows = list(
                (await session.execute(select(DocumentRow).order_by(DocumentRow.created_at))).scalars()
            )
        return [self._info(r).model_dump(mode="json") for r in rows]

    # ------------------------------------------------------------ storage-mcp

    async def storage_list(self, prefix: str = "", limit: int = 100) -> tuple[list[StoredObjectInfo], bool]:
        objects = await self._objects.list(prefix)
        titles = await self._titles()
        items = [self._stored(o.key, o.size, o.content_type, titles) for o in objects[:limit]]
        return items, len(objects) > limit

    async def storage_stat(self, key: str) -> StoredObjectInfo | None:
        for obj in await self._objects.list(key):
            if obj.key == key:
                return self._stored(obj.key, obj.size, obj.content_type, await self._titles())
        return None

    async def _titles(self) -> dict[str, tuple[str, str]]:
        async with self._sf() as session:
            rows = (
                await session.execute(select(DocumentRow.id, DocumentRow.title, DocumentRow.object_key))
            ).all()
        return {key: (doc_id, title) for doc_id, title, key in rows}

    @staticmethod
    def _stored(
        key: str, size: int, content_type: str | None, titles: dict[str, tuple[str, str]]
    ) -> StoredObjectInfo:
        doc = titles.get(key)
        media = content_type or ex.MEDIA_TYPES.get(key.rsplit(".", 1)[-1])
        return StoredObjectInfo(
            key=key,
            size=size,
            content_type=media,
            document_id=doc[0] if doc else None,
            title=doc[1] if doc else None,
        )
