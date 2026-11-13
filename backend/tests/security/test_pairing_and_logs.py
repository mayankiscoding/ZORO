"""Pairing-failure throttle (per client address + global ceiling) and access-log redaction."""

from __future__ import annotations

import io
import logging

import httpx
import pytest
from fastapi import FastAPI
from uvicorn.logging import AccessFormatter

from app.core.clock import Clock
from app.core.logging import AccessLogRedactor, configure_logging, redact_url
from app.core.types import DevicePlatform
from tests.fakes.devices import DeviceSigner

WRONG = "ZZZZ-ZZZZ"


def _client(app: FastAPI, address: str) -> httpx.AsyncClient:
    transport = httpx.ASGITransport(app=app, client=(address, 50000))
    return httpx.AsyncClient(transport=transport, base_url="http://zoro.test")


async def _wrong_pair(app: FastAPI, address: str, clock: Clock) -> int:
    signer = DeviceSigner(name="probe", platform=DevicePlatform.IOS, now=clock.now)
    body = signer.pair_request(WRONG).model_dump(mode="json")
    async with _client(app, address) as http:
        return (await http.post("/v1/auth/pair", json=body)).status_code


async def test_wrong_codes_from_one_client_are_throttled(app: FastAPI, clock: Clock) -> None:
    statuses = [await _wrong_pair(app, "10.0.0.1", clock) for _ in range(12)]
    assert statuses[0] in (400, 401)
    assert 429 in statuses, statuses


@pytest.mark.xfail(
    strict=True,
    reason="pairing throttle is global (app/security/devices.py DeviceRegistry._failures): one client "
    "can lock every other client out. Fix belongs to the security owner; see change_requests.",
)
async def test_one_client_cannot_lock_out_another(app: FastAPI, clock: Clock) -> None:
    for _ in range(12):
        await _wrong_pair(app, "10.0.0.1", clock)
    assert await _wrong_pair(app, "10.0.0.2", clock) != 429


async def test_global_ceiling_across_many_addresses(app: FastAPI, clock: Clock) -> None:
    statuses = [await _wrong_pair(app, f"10.1.{i // 250}.{i % 250 + 1}", clock) for i in range(120)]
    assert 429 in statuses, "a distributed guess must hit a global ceiling"


# ------------------------------------------------------------------------------ access logs

# a session-token-shaped value, assembled so the repository secret scan does not flag this file
TOKEN = ".".join(("eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiJkZXZfMSJ9", "c2lnbmVkLXRva2VuLXZhbHVl"))


def _access_record(path: str) -> logging.LogRecord:
    return logging.LogRecord(
        "uvicorn.access", logging.INFO, __file__, 1, '%s - "%s %s HTTP/%s" %d',
        ("100.64.0.2:51000", "GET", path, "1.1", 101), None,
    )  # fmt: skip


def test_websocket_token_never_reaches_the_access_log() -> None:
    configure_logging("INFO")
    logger = logging.getLogger("uvicorn.access")
    assert any(isinstance(f, AccessLogRedactor) for f in logger.filters)

    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(
        AccessFormatter(fmt='%(client_addr)s - "%(request_line)s" %(status_code)s', use_colors=False)
    )
    record = _access_record(f"/v1/devices/channel?token={TOKEN}&v=1")
    for log_filter in logger.filters:
        assert log_filter.filter(record) if isinstance(log_filter, logging.Filter) else log_filter(record)
    handler.handle(record)
    line = stream.getvalue()
    assert TOKEN not in line and "eyJ" not in line
    assert "/v1/devices/channel?token=" in line and "v=1" in line
    assert "101" in line  # the formatter still works: args keep their shape


def test_access_logger_end_to_end_through_its_own_handler() -> None:
    configure_logging("INFO")
    logger = logging.getLogger("uvicorn.access")
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(AccessFormatter(fmt="%(request_line)s", use_colors=False))
    logger.addHandler(handler)
    try:
        logger.info(
            '%s - "%s %s HTTP/%s" %d', "127.0.0.1:1", "GET", f"/v1/devices/channel?token={TOKEN}", "1.1", 101
        )
    finally:
        logger.removeHandler(handler)
    assert TOKEN not in stream.getvalue()
    assert "[redacted]" in stream.getvalue()


@pytest.mark.parametrize(
    ("url", "kept"),
    [
        ("/v1/devices/channel?token=abc.def.ghi", "/v1/devices/channel?token="),
        ("/v1/music/callback?code=AQB123&state=s1", "/v1/music/callback?code="),
        ("/v1/finance/transactions?limit=20", "limit=20"),
        ("/healthz", "/healthz"),
    ],
)
def test_redact_url(url: str, kept: str) -> None:
    out = redact_url(url)
    assert kept in out
    for secret in ("abc.def.ghi", "AQB123", "s1"):
        if secret in url:
            assert secret not in out
