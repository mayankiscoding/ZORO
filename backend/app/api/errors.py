"""Error handlers: every failure leaves the API as `ErrorBody` with a stable `code`."""

from __future__ import annotations

import logging

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.requests import HTTPConnection
from starlette.responses import JSONResponse, Response
from starlette.websockets import WebSocket

from app.core.errors import ZoroError
from app.schemas.common import ErrorBody

log = logging.getLogger(__name__)

_HTTP_CODES = {
    400: "bad_request",
    401: "unauthorized",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
    409: "conflict",
    413: "payload_too_large",
    415: "unsupported_media_type",
    422: "validation_error",
    429: "rate_limited",
    503: "unavailable",
}


def error_response(status: int, body: ErrorBody) -> JSONResponse:
    headers = {"WWW-Authenticate": "Bearer"} if status == 401 else None
    return JSONResponse(status_code=status, content=body.model_dump(mode="json"), headers=headers)


async def _close_websocket(conn: HTTPConnection, code: str) -> bool:
    if isinstance(conn, WebSocket):
        await conn.close(code=1008, reason=code[:120])
        return True
    return False


async def _zoro_error(conn: HTTPConnection, exc: Exception) -> Response:
    assert isinstance(exc, ZoroError)
    if exc.status >= 500 and exc.error_code not in {"kill_switch_active", "unavailable"}:
        log.error("request failed", extra={"code": exc.error_code, "path": conn.url.path})
    if await _close_websocket(conn, exc.error_code):
        return Response(status_code=exc.status)
    return error_response(exc.status, exc.to_body())


async def _validation_error(conn: HTTPConnection, exc: Exception) -> Response:
    assert isinstance(exc, RequestValidationError)
    # Field paths and reasons only: never echo the submitted values back or into logs.
    problems = [
        {"field": ".".join(str(part) for part in error.get("loc", ())), "problem": str(error.get("msg", ""))}
        for error in exc.errors()
    ]
    body = ErrorBody(
        code="validation_error",
        message="The request body or parameters are not valid.",
        detail={"errors": problems},
    )
    return error_response(422, body)


async def _http_error(conn: HTTPConnection, exc: Exception) -> Response:
    assert isinstance(exc, StarletteHTTPException)
    code = _HTTP_CODES.get(exc.status_code, "http_error")
    message = exc.detail if isinstance(exc.detail, str) else "The request could not be handled."
    if await _close_websocket(conn, code):
        return Response(status_code=exc.status_code)
    return error_response(
        exc.status_code, ErrorBody(code=code, message=message, retryable=exc.status_code == 503)
    )


async def _unhandled(conn: HTTPConnection, exc: Exception) -> Response:
    log.error("unhandled error", extra={"error_type": type(exc).__name__, "path": conn.url.path})
    body = ErrorBody(
        code="internal_error", message="Something went wrong on the ZORO server.", retryable=True
    )
    return error_response(500, body)


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(ZoroError, _zoro_error)
    app.add_exception_handler(RequestValidationError, _validation_error)
    app.add_exception_handler(StarletteHTTPException, _http_error)
    app.add_exception_handler(Exception, _unhandled)
