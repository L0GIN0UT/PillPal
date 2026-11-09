"""Download of the Roszdravnadzor recall list: one CSV file at the https URL the operator names.

Same rules as every fetch (``fetch.py``): https only, host allow-list on every redirect hop, byte
cap on the decoded stream, optional pinned sha256, nothing kept on failure. The file must look
like a CSV (a login or captcha page is HTML, an archive starts with ``PK``) and is read once end
to end by ``validate`` before it is kept.
"""

from __future__ import annotations

import re
import shutil
import tempfile
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

import httpx

from catalog.importers.base import ImporterError, SnapshotManifest
from catalog.importers.fetch import (
    check_url,
    discard_destination,
    download_file,
    new_client,
    prepare_destination,
)

SOURCE = "ru_roszdravnadzor"
ALLOWED_HOSTS = frozenset({"roszdravnadzor.gov.ru", "www.roszdravnadzor.gov.ru"})
MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024
CSV_NAME = "recalls.csv"
_SHA256 = re.compile(r"[0-9a-fA-F]{64}", re.ASCII)
_NOT_CSV_PREFIXES = (b"<", b"PK", b"%PDF")
_SNIFF_BYTES = 16


def fetch_snapshot(
    dest: Path,
    *,
    transport: httpx.BaseTransport | None,
    retrieved_at: datetime,
    url: str | None,
    expected_sha256: str | None,
    max_bytes: int = MAX_DOWNLOAD_BYTES,
    validate: Callable[[Path], None],
) -> SnapshotManifest:
    if url is None:
        raise ImporterError("url_required")
    check_url(url, ALLOWED_HOSTS)
    if expected_sha256 is not None and _SHA256.fullmatch(expected_sha256) is None:
        raise ImporterError("invalid_checksum")
    created = prepare_destination(dest)
    try:
        with new_client(transport) as client, tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
            download = Path(tmp) / CSV_NAME
            result = download_file(
                client,
                url,
                download,
                max_bytes=max_bytes,
                allowed_hosts=ALLOWED_HOSTS,
                expected_sha256=expected_sha256,
            )
            with download.open("rb") as handle:
                head = handle.read(_SNIFF_BYTES).lstrip(b"\xef\xbb\xbf")
            if not head or head.startswith(_NOT_CSV_PREFIXES):
                raise ImporterError("invalid_download")
            dest.mkdir(parents=True, exist_ok=True)
            shutil.move(str(download), str(dest / CSV_NAME))
        validate(dest)
    except BaseException:
        discard_destination(dest, created)
        raise
    return SnapshotManifest(
        source=SOURCE, version=None, sha256=result.sha256, retrieved_at=retrieved_at, url=url
    )
