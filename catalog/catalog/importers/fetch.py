"""Network side of the importers (the only place that talks to a source's server).

A snapshot download is untrusted: https only, an allow-list of hosts that every redirect hop must
satisfy (no credentials in URLs, no downgrade), a byte cap enforced on the decoded stream (a
declared ``Content-Length`` is only an early exit), and an optional pinned sha256. Failures carry
a stable code and never the URL, headers or body: nothing of the exchange is chained either.

TLS is always verified. The Ministry of Health portal (``*.rosminzdrav.ru``) chains to the
Russian Trusted Root CA, which certifi does not ship; the operator may add that root from a file
(``CATALOG_IMPORTER_RU_CA_FILE``, docs/staging.md section 12.2). It is added to certifi's roots,
never replaces them, and only for a client whose every allowed host is a rosminzdrav.ru host
(redirect hops are held to the same list), so no other source ever trusts it.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import ssl
import time
from collections.abc import Callable, Collection
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import certifi
import httpx

from catalog.importers.base import ImporterError

MAX_REDIRECTS = 3
CHUNK_BYTES = 64 * 1024
CONNECT_TIMEOUT_SECONDS = 30.0
READ_TIMEOUT_SECONDS = 120.0
# One download may not take longer than this, however slowly the server drips bytes.
FETCH_DEADLINE_SECONDS = 3600.0
USER_AGENT = "pillpal-catalog-importer"
HTTPS = "https"
# The only hosts an operator-supplied extra CA may be used for (see the module docstring).
EXTRA_CA_HOST_SUFFIX = ".rosminzdrav.ru"
MAX_CA_FILE_BYTES = 64 * 1024
_PEM_CERT = re.compile(
    r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", re.DOTALL | re.ASCII
)


@dataclass(frozen=True)
class Download:
    sha256: str
    size: int


def trust_context(extra_ca_file: Path, expected_sha256: str | None = None) -> ssl.SSLContext:
    """certifi's roots plus the CA certificates in ``extra_ca_file``; hostname and chain checks
    stay on. With ``expected_sha256`` the file must hold exactly one certificate whose DER
    SHA-256 is that value. An unreadable file, one without a certificate or a mismatch is
    refused (the path is not echoed)."""
    context = ssl.create_default_context(cafile=certifi.where())
    try:
        if expected_sha256 is None:
            context.load_verify_locations(cafile=str(extra_ca_file))
        else:
            context.load_verify_locations(cadata=_pinned(extra_ca_file, expected_sha256))
    except (OSError, ssl.SSLError, ValueError):
        raise ImporterError("ca_file_invalid") from None
    return context


def _pinned(extra_ca_file: Path, expected_sha256: str) -> bytes:
    """The DER of the file's single certificate, when it has the expected fingerprint."""
    with extra_ca_file.open("rb") as handle:
        text = handle.read(MAX_CA_FILE_BYTES + 1).decode("ascii")
    blocks = _PEM_CERT.findall(text)
    if len(text) > MAX_CA_FILE_BYTES or len(blocks) != 1:
        raise ValueError
    der = ssl.PEM_cert_to_DER_cert(blocks[0])
    if hashlib.sha256(der).hexdigest() != expected_sha256.lower():
        raise ValueError
    return der


def new_client(
    transport: httpx.BaseTransport | None = None,
    *,
    allowed_hosts: Collection[str] = (),
    extra_ca_file: Path | None = None,
    extra_ca_sha256: str | None = None,
) -> httpx.Client:
    """A client that follows no redirects by itself: ``_exchange`` checks every hop.

    ``extra_ca_file`` is accepted only when ``allowed_hosts`` is non-empty and every host in it
    ends with ``EXTRA_CA_HOST_SUFFIX``."""
    verify: ssl.SSLContext | bool = True
    if extra_ca_file is not None:
        if not allowed_hosts or not all(h.endswith(EXTRA_CA_HOST_SUFFIX) for h in allowed_hosts):
            raise ImporterError("extra_ca_not_allowed")
        verify = trust_context(extra_ca_file, extra_ca_sha256)
    return httpx.Client(
        transport=transport,
        verify=verify,
        timeout=httpx.Timeout(CONNECT_TIMEOUT_SECONDS, read=READ_TIMEOUT_SECONDS),
        follow_redirects=False,
        trust_env=False,  # no proxy or CA settings from the environment
        headers={"User-Agent": USER_AGENT},
    )


def check_url(url: httpx.URL | str, allowed_hosts: Collection[str]) -> httpx.URL:
    try:
        parsed = httpx.URL(url)
    except httpx.InvalidURL:
        raise ImporterError("fetch_failed") from None
    if parsed.scheme != HTTPS:
        raise ImporterError("fetch_insecure_url")
    if parsed.userinfo or parsed.port is not None or parsed.host not in allowed_hosts:
        raise ImporterError("fetch_host_not_allowed")
    return parsed


def _exchange[T](
    client: httpx.Client,
    url: httpx.URL | str,
    allowed_hosts: Collection[str],
    consume: Callable[[httpx.Response], T],
) -> T:
    current = check_url(url, allowed_hosts)
    for _ in range(MAX_REDIRECTS + 1):
        try:
            with client.stream("GET", current) as response:
                if not response.is_redirect:
                    if response.status_code != httpx.codes.OK:
                        raise ImporterError("fetch_failed")
                    return consume(response)
                current = check_url(
                    response.url.join(response.headers.get("location", "")), allowed_hosts
                )
        except (httpx.HTTPError, httpx.InvalidURL):
            raise ImporterError("fetch_failed") from None
    raise ImporterError("fetch_failed")


def _declared_too_large(response: httpx.Response, max_bytes: int) -> bool:
    declared = response.headers.get("content-length", "")
    return declared.isdigit() and int(declared) > max_bytes


def _copy_limited(
    response: httpx.Response,
    target: Path,
    max_bytes: int,
    max_seconds: float,
    clock: Callable[[], float],
) -> Download:
    digest = hashlib.sha256()
    size = 0
    started = clock()
    try:
        with target.open("wb") as out:
            for chunk in response.iter_bytes(CHUNK_BYTES):
                size += len(chunk)
                if clock() - started > max_seconds:
                    raise ImporterError("fetch_timeout")
                if size > max_bytes:
                    raise ImporterError("download_too_large")
                digest.update(chunk)
                out.write(chunk)
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    return Download(sha256=digest.hexdigest(), size=size)


def download_file(
    client: httpx.Client,
    url: str,
    target: Path,
    *,
    max_bytes: int,
    allowed_hosts: Collection[str],
    expected_sha256: str | None = None,
    max_seconds: float = FETCH_DEADLINE_SECONDS,
    clock: Callable[[], float] = time.monotonic,
) -> Download:
    """Download ``url`` into ``target``; on any failure ``target`` does not exist afterwards."""

    def consume(response: httpx.Response) -> Download:
        if _declared_too_large(response, max_bytes):
            raise ImporterError("download_too_large")
        result = _copy_limited(response, target, max_bytes, max_seconds, clock)
        if expected_sha256 is not None and result.sha256 != expected_sha256.lower():
            target.unlink(missing_ok=True)
            raise ImporterError("checksum_mismatch")
        return result

    return _exchange(client, url, allowed_hosts, consume)


def get_json(
    client: httpx.Client, url: str, *, max_bytes: int, allowed_hosts: Collection[str]
) -> Any:
    """A small JSON document (an index of files), held in memory under ``max_bytes``."""

    def consume(response: httpx.Response) -> Any:
        if _declared_too_large(response, max_bytes):
            raise ImporterError("download_too_large")
        body = bytearray()
        for chunk in response.iter_bytes(CHUNK_BYTES):
            body.extend(chunk)
            if len(body) > max_bytes:
                raise ImporterError("download_too_large")
        try:
            return json.loads(bytes(body))
        except (ValueError, RecursionError):
            raise ImporterError("invalid_download") from None

    return _exchange(client, url, allowed_hosts, consume)


def prepare_destination(dest: Path) -> bool:
    """Refuse a destination that already holds files; returns whether ``dest`` is new."""
    if dest.exists() and any(dest.iterdir()):
        raise ImporterError("destination_not_empty")
    dest.parent.mkdir(parents=True, exist_ok=True)
    return not dest.exists()


def discard_destination(dest: Path, created: bool) -> None:
    """Undo a failed fetch: remove ``dest``, or empty it if it existed before."""
    if created:
        shutil.rmtree(dest, ignore_errors=True)
        return
    for child in dest.iterdir():
        if child.is_dir():
            shutil.rmtree(child, ignore_errors=True)
        else:
            child.unlink()
