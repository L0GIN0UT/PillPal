"""Network side of the importers (the only place that talks to a source's server).

A snapshot download is untrusted: https only, an allow-list of hosts that every redirect hop must
satisfy (no credentials in URLs, no downgrade), a byte cap enforced on the decoded stream (a
declared ``Content-Length`` is only an early exit), and an optional pinned sha256. Failures carry
a stable code and never the URL, headers or body: nothing of the exchange is chained either.
"""

from __future__ import annotations

import hashlib
import json
import shutil
from collections.abc import Callable, Collection
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx

from catalog.importers.base import ImporterError

MAX_REDIRECTS = 3
CHUNK_BYTES = 64 * 1024
CONNECT_TIMEOUT_SECONDS = 30.0
READ_TIMEOUT_SECONDS = 120.0
USER_AGENT = "pillpal-catalog-importer"
HTTPS = "https"


@dataclass(frozen=True)
class Download:
    sha256: str
    size: int


def new_client(transport: httpx.BaseTransport | None = None) -> httpx.Client:
    """A client that follows no redirects by itself: ``_exchange`` checks every hop."""
    return httpx.Client(
        transport=transport,
        timeout=httpx.Timeout(CONNECT_TIMEOUT_SECONDS, read=READ_TIMEOUT_SECONDS),
        follow_redirects=False,
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
                current = check_url(response.url.join(response.headers["location"]), allowed_hosts)
        except (httpx.HTTPError, httpx.InvalidURL):
            raise ImporterError("fetch_failed") from None
    raise ImporterError("fetch_failed")


def _declared_too_large(response: httpx.Response, max_bytes: int) -> bool:
    declared = response.headers.get("content-length", "")
    return declared.isdigit() and int(declared) > max_bytes


def _copy_limited(response: httpx.Response, target: Path, max_bytes: int) -> Download:
    digest = hashlib.sha256()
    size = 0
    try:
        with target.open("wb") as out:
            for chunk in response.iter_bytes(CHUNK_BYTES):
                size += len(chunk)
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
) -> Download:
    """Download ``url`` into ``target``; on any failure ``target`` does not exist afterwards."""

    def consume(response: httpx.Response) -> Download:
        if _declared_too_large(response, max_bytes):
            raise ImporterError("download_too_large")
        result = _copy_limited(response, target, max_bytes)
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
        except ValueError:
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
