"""Download of the EMA medicines workbook: one https URL (the public default, or the operator's).

Same rules as every fetch (``fetch.py``): https only, host allow-list on every redirect hop, byte
cap on the decoded stream, deadline, optional pinned sha256, nothing kept on failure. The file must
be a workbook (a login or error page is HTML; the check is the zip magic plus the workbook part)
and is read once end to end by ``validate`` before it is kept, because a truncated list would make
the next run withdraw every medicine it lacks.
"""

from __future__ import annotations

import re
import shutil
import tempfile
import zipfile
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

SOURCE = "ema"
ALLOWED_HOSTS = frozenset({"www.ema.europa.eu", "ema.europa.eu"})
# Unverified: the address of the "Medicines output" report on the EMA site; pass --url to override.
DEFAULT_URL = (
    "https://www.ema.europa.eu/en/documents/report/medicines-output-medicines-report_en.xlsx"
)
MAX_DOWNLOAD_BYTES = 128 * 1024 * 1024
WORKBOOK_NAME = "ema.xlsx"
_ZIP_MAGIC = b"PK"
_SHA256 = re.compile(r"[0-9a-fA-F]{64}", re.ASCII)


def _is_workbook(path: Path) -> bool:
    with path.open("rb") as handle:
        if not handle.read(len(_ZIP_MAGIC)).startswith(_ZIP_MAGIC):
            return False
    try:
        with zipfile.ZipFile(path) as archive:
            return "xl/workbook.xml" in archive.namelist()
    except zipfile.BadZipFile:
        return False


def fetch_snapshot(
    dest: Path,
    *,
    transport: httpx.BaseTransport | None,
    retrieved_at: datetime,
    url: str,
    expected_sha256: str | None,
    max_bytes: int = MAX_DOWNLOAD_BYTES,
    validate: Callable[[Path], None],
) -> SnapshotManifest:
    check_url(url, ALLOWED_HOSTS)
    if expected_sha256 is not None and _SHA256.fullmatch(expected_sha256) is None:
        raise ImporterError("invalid_checksum")
    created = prepare_destination(dest)
    try:
        with new_client(transport) as client, tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
            download = Path(tmp) / WORKBOOK_NAME
            result = download_file(
                client,
                url,
                download,
                max_bytes=max_bytes,
                allowed_hosts=ALLOWED_HOSTS,
                expected_sha256=expected_sha256,
            )
            if not _is_workbook(download):
                raise ImporterError("invalid_download")
            dest.mkdir(parents=True, exist_ok=True)
            shutil.move(str(download), str(dest / WORKBOOK_NAME))
        validate(dest)
    except BaseException:
        discard_destination(dest, created)
        raise
    return SnapshotManifest(
        source=SOURCE, version=None, sha256=result.sha256, retrieved_at=retrieved_at, url=url
    )
