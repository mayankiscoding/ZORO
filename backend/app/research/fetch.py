"""SSRF-safe page fetcher.

https only, no credentials in the URL, port 443 only. The host is resolved first and every address
is checked: private, loopback, link-local (incl. cloud metadata 169.254.169.254), shared/CGNAT
(100.64/10, also Tailscale), multicast, reserved and unspecified addresses are refused, including
IPv4-mapped / NAT64 IPv6 forms. The connection goes to the vetted address (Host header and TLS SNI
keep the name, so certificates are still verified) which closes the DNS-rebinding gap. Redirects
are followed by hand and every hop is checked again. Size, time and content type are limited.
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime
from urllib.parse import urljoin, urlsplit, urlunsplit

import httpx

from app.core.clock import Clock, SystemClock
from app.research.extract import extract_text

Resolver = Callable[[str, int], Awaitable[list[str]]]

ALLOWED_TYPES = frozenset(
    {
        "text/html",
        "application/xhtml+xml",
        "text/plain",
        "application/json",
        "text/markdown",
        "application/ld+json",
    }
)
_REDIRECTS = frozenset({301, 302, 303, 307, 308})
_NAT64 = ipaddress.ip_network("64:ff9b::/96")
_USER_AGENT = "ZORO-research/0.1 (personal assistant; fetches pages the owner asked for)"


class FetchError(Exception):
    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code


@dataclass(frozen=True)
class FetchLimits:
    max_bytes: int = 2_000_000
    timeout_s: float = 15.0
    max_redirects: int = 5
    allowed_types: frozenset[str] = field(default=ALLOWED_TYPES)


@dataclass(frozen=True)
class FetchedPage:
    url: str
    final_url: str
    status: int
    content_type: str
    title: str
    text: str
    truncated: bool
    retrieved_at: datetime


def address_blocked(ip: str) -> bool:
    """True for anything that is not a public unicast address."""
    try:
        addr = ipaddress.ip_address(ip.split("%", 1)[0])
    except ValueError:
        return True
    if isinstance(addr, ipaddress.IPv6Address):
        if addr.ipv4_mapped is not None:
            return address_blocked(str(addr.ipv4_mapped))
        if addr in _NAT64:
            return address_blocked(str(ipaddress.IPv4Address(int(addr) & 0xFFFFFFFF)))
        if addr.sixtofour is not None or addr.teredo is not None:
            return True
    return (
        not addr.is_global
        or addr.is_multicast
        or addr.is_private
        or addr.is_loopback
        or addr.is_link_local
        or addr.is_reserved
        or addr.is_unspecified
    )


async def system_resolver(host: str, port: int) -> list[str]:
    loop = asyncio.get_running_loop()
    try:
        infos = await loop.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise FetchError("dns_failed") from exc
    return list(dict.fromkeys(str(info[4][0]) for info in infos))


def check_url(url: str) -> tuple[str, int]:
    """Validate the URL shape; returns (host, port)."""
    try:
        parts = urlsplit(url.strip())
        port = parts.port or 443
    except ValueError as exc:
        raise FetchError("invalid_url") from exc
    if parts.scheme.lower() != "https":
        raise FetchError("https_only")
    if parts.username is not None or parts.password is not None:
        raise FetchError("credentials_in_url")
    if not parts.hostname:
        raise FetchError("invalid_url")
    if port != 443:
        raise FetchError("port_not_allowed")
    return parts.hostname.rstrip(".").lower(), port


class SafeFetcher:
    def __init__(
        self,
        *,
        resolver: Resolver | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        limits: FetchLimits | None = None,
        clock: Clock | None = None,
    ) -> None:
        self._resolve = resolver or system_resolver
        self._transport = transport
        self.limits = limits or FetchLimits()
        self._clock = clock or SystemClock()

    async def _vetted_address(self, host: str, port: int) -> str:
        addresses = await self._resolve(host, port)
        if not addresses:
            raise FetchError("dns_failed")
        if any(address_blocked(a) for a in addresses):
            raise FetchError("blocked_address", f"{host} resolves to a non-public address")
        return addresses[0]

    async def fetch(self, url: str) -> FetchedPage:
        try:
            async with asyncio.timeout(self.limits.timeout_s):
                return await self._fetch(url)
        except TimeoutError as exc:
            raise FetchError("timeout") from exc
        except httpx.TimeoutException as exc:
            raise FetchError("timeout") from exc
        except httpx.HTTPError as exc:
            raise FetchError("network_error", type(exc).__name__) from exc

    async def _fetch(self, url: str) -> FetchedPage:
        current = url.strip()
        timeout = httpx.Timeout(self.limits.timeout_s, connect=5.0)
        async with httpx.AsyncClient(
            transport=self._transport, timeout=timeout, follow_redirects=False, trust_env=False
        ) as http:
            for _ in range(self.limits.max_redirects + 1):
                host, port = check_url(current)
                ip = await self._vetted_address(host, port)
                parts = urlsplit(current)
                netloc = f"[{ip}]" if ":" in ip else ip
                target = urlunsplit(("https", netloc, parts.path or "/", parts.query, ""))
                request = http.build_request(
                    "GET",
                    target,
                    headers={
                        "Host": host,
                        "User-Agent": _USER_AGENT,
                        "Accept": ", ".join(sorted(self.limits.allowed_types)),
                    },
                    extensions={"sni_hostname": host},
                )
                response = await http.send(request, stream=True)
                try:
                    if response.status_code in _REDIRECTS:
                        location = response.headers.get("location")
                        if not location:
                            raise FetchError("redirect_without_location")
                        current = urljoin(current, location)
                        continue
                    return await self._read(url, current, response)
                finally:
                    await response.aclose()
        raise FetchError("too_many_redirects")

    async def _read(self, url: str, final_url: str, response: httpx.Response) -> FetchedPage:
        if response.status_code != 200:
            raise FetchError(f"http_{response.status_code}")
        raw_type = response.headers.get("content-type", "")
        content_type = raw_type.split(";", 1)[0].strip().lower()
        if content_type not in self.limits.allowed_types:
            raise FetchError("content_type_not_allowed", content_type or "missing")
        declared = response.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > self.limits.max_bytes * 4:
            raise FetchError("too_large")
        body = bytearray()
        truncated = False
        async for chunk in response.aiter_bytes():
            body.extend(chunk)
            if len(body) > self.limits.max_bytes:
                del body[self.limits.max_bytes :]
                truncated = True
                break
        charset = response.charset_encoding or "utf-8"
        try:
            decoded = bytes(body).decode(charset, errors="replace")
        except LookupError:
            decoded = bytes(body).decode("utf-8", errors="replace")
        title, text = extract_text(decoded, content_type)
        return FetchedPage(
            url=url,
            final_url=final_url,
            status=response.status_code,
            content_type=content_type,
            title=title,
            text=text,
            truncated=truncated,
            retrieved_at=self._clock.now(),
        )
