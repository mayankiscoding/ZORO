"""`/v1/documents`: upload (multipart), list, search, read, delete."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request, Response
from starlette.datastructures import UploadFile

from app.api.deps import CurrentDevice, Registry, require_device
from app.core.errors import BadRequest
from app.core.types import DataClass
from app.documents.extract import DocumentTooLarge, LengthRequired
from app.documents.schemas import DocumentHit, DocumentInfo
from app.documents.service import DocumentService
from app.schemas.common import Page

router = APIRouter(prefix="/documents", tags=["documents"], dependencies=[Depends(require_device)])

_MULTIPART_OVERHEAD = 256 * 1024


def _service(reg: Registry) -> DocumentService:
    service: DocumentService = reg.service("documents")
    return service


@router.post("", response_model=DocumentInfo, status_code=201)
async def upload_document(
    request: Request, reg: Registry, device: CurrentDevice, response: Response
) -> DocumentInfo:
    """multipart/form-data with `file` (required) and `sensitivity` (optional, default personal)."""
    service = _service(reg)
    declared = request.headers.get("content-length")
    if declared is None or not declared.isdigit():
        raise LengthRequired()
    if int(declared) > service.max_bytes + _MULTIPART_OVERHEAD:
        raise DocumentTooLarge(f"This file is larger than the {service.max_bytes // (1024 * 1024)} MB limit.")
    form = await request.form(max_files=1, max_fields=4)
    upload = form.get("file")
    if not isinstance(upload, UploadFile):
        raise BadRequest("Send the document as a multipart form field named 'file'.", code="file_missing")
    try:
        sensitivity = DataClass(str(form.get("sensitivity") or "personal"))
    except ValueError:
        raise BadRequest("Unknown sensitivity.", code="sensitivity_invalid") from None
    if sensitivity is DataClass.SECRET:
        raise BadRequest("Credentials are never stored.", code="sensitivity_invalid")
    data = await upload.read(service.max_bytes + 1)
    info, created = await service.upload(
        upload.filename or "document", data, sensitivity=sensitivity, actor=device.device_id
    )
    if not created:
        response.status_code = 200  # identical content was already stored
    return info


@router.get("", response_model=Page[DocumentInfo])
async def list_documents(
    reg: Registry, cursor: str | None = None, limit: Annotated[int, Query(ge=1, le=200)] = 50
) -> Page[DocumentInfo]:
    return await _service(reg).list_documents(cursor=cursor, limit=limit)


@router.get("/search", response_model=Page[DocumentHit])
async def search_documents(
    reg: Registry,
    q: Annotated[str, Query(min_length=1, max_length=300)],
    limit: Annotated[int, Query(ge=1, le=50)] = 10,
) -> Page[DocumentHit]:
    return Page[DocumentHit](items=await _service(reg).search(q, limit=limit, min_score=0.15))


@router.get("/{document_id}", response_model=DocumentInfo)
async def get_document(document_id: str, reg: Registry) -> DocumentInfo:
    return await _service(reg).get(document_id)


@router.get("/{document_id}/content")
async def get_document_content(document_id: str, reg: Registry) -> Response:
    data, media_type, title = await _service(reg).read_original(document_id)
    safe = "".join(ch for ch in title if ch.isalnum() or ch in "._- ") or "document"
    return Response(
        data, media_type=media_type, headers={"Content-Disposition": f'attachment; filename="{safe}"'}
    )


@router.delete("/{document_id}", status_code=204)
async def delete_document(document_id: str, reg: Registry, device: CurrentDevice) -> Response:
    service = _service(reg)
    await service.get(document_id)  # 404 document_not_found
    await service.delete(document_id, actor=device.device_id)
    return Response(status_code=204)
