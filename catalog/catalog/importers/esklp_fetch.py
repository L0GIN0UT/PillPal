"""Download of the ESKLP file the operator names (``--url``).

Nothing is scraped and no link is guessed: the operator gives the exact https URL of the file
(found by hand on esklp.egisz.rosminzdrav.ru, owner checklist step 1) and this module downloads
that one file under the shared rules of ``fetch.py`` (https only, host allow-list on every
redirect hop, byte cap on the decoded stream, deadline, optional pinned sha256).

The result must be a snapshot the importer can read, or nothing is kept: a workbook is stored as
``esklp.xlsx``, a zip of XML files is extracted with the archive guards, a bare XML file is stored
as ``esklp.xml``, anything else (a login page, an error document) is refused, and the stored
files are read once end to end (``empty_snapshot`` / ``missing_columns`` / ``invalid_snapshot``),
because a truncated file would make the next run withdraw every product it lacks.
"""

from __future__ import annotations

import re
import shutil
import tempfile
import zipfile
from datetime import datetime
from pathlib import Path

import httpx

from catalog.importers.archive import ArchiveLimits, safe_extract_zip
from catalog.importers.base import ImporterDataError, ImporterError, SnapshotManifest
from catalog.importers.esklp_source import (
    KLP,
    MAX_XML_FILE_BYTES,
    MAX_XML_FILES,
    iter_items,
    read_version,
)
from catalog.importers.fetch import (
    check_url,
    discard_destination,
    download_file,
    new_client,
    prepare_destination,
)
from catalog.importers.ru_common import ESKLP_SOURCE

ALLOWED_HOSTS = frozenset({"esklp.egisz.rosminzdrav.ru"})
MAX_DOWNLOAD_BYTES = 1024**3
EXTRACT_LIMITS = ArchiveLimits(
    max_files=MAX_XML_FILES, max_total_bytes=4 * 1024**3, max_file_bytes=MAX_XML_FILE_BYTES
)
WORKBOOK_NAME = "esklp.xlsx"
XML_NAME = "esklp.xml"
_ZIP_MAGIC = b"PK"
_XML_START = re.compile(rb"(?:\xef\xbb\xbf)?\s*<\?xml")
_SHA256 = re.compile(r"[0-9a-fA-F]{64}", re.ASCII)
_SNIFF_BYTES = 64


def _place(download: Path, dest: Path) -> None:
    with download.open("rb") as handle:
        head = handle.read(_SNIFF_BYTES)
    dest.mkdir(parents=True, exist_ok=True)
    if head.startswith(_ZIP_MAGIC):
        try:
            with zipfile.ZipFile(download) as archive:
                is_workbook = "xl/workbook.xml" in archive.namelist()
        except zipfile.BadZipFile:
            raise ImporterError("invalid_download") from None
        if is_workbook:
            shutil.move(str(download), str(dest / WORKBOOK_NAME))
            return
        safe_extract_zip(download, dest, EXTRACT_LIMITS)
        if not any(dest.iterdir()) or any(
            p.suffix.lower() != ".xml" for p in dest.rglob("*") if p.is_file()
        ):
            raise ImporterError("invalid_download")
    elif _XML_START.match(head):
        shutil.move(str(download), str(dest / XML_NAME))
    else:
        raise ImporterError("invalid_download")


def _read_through(dest: Path) -> None:
    """Parse the stored snapshot end to end; any defect raises and the fetch is discarded."""
    if sum(1 for kind, _ in iter_items(dest) if kind == KLP) == 0:
        raise ImporterDataError("empty_snapshot")


def fetch_snapshot(
    dest: Path,
    *,
    transport: httpx.BaseTransport | None,
    retrieved_at: datetime,
    url: str | None,
    expected_sha256: str | None,
    max_bytes: int = MAX_DOWNLOAD_BYTES,
    extra_ca_file: Path | None = None,
    extra_ca_sha256: str | None = None,
) -> SnapshotManifest:
    if url is None:
        raise ImporterError("url_required")
    check_url(url, ALLOWED_HOSTS)
    if expected_sha256 is not None and _SHA256.fullmatch(expected_sha256) is None:
        raise ImporterError("invalid_checksum")
    created = prepare_destination(dest)
    try:
        client = new_client(
            transport,
            allowed_hosts=ALLOWED_HOSTS,
            extra_ca_file=extra_ca_file,
            extra_ca_sha256=extra_ca_sha256,
        )
        with client, tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
            download = Path(tmp) / "download"
            result = download_file(
                client,
                url,
                download,
                max_bytes=max_bytes,
                allowed_hosts=ALLOWED_HOSTS,
                expected_sha256=expected_sha256,
            )
            _place(download, dest)
        _read_through(dest)
        version = read_version(dest)
    except BaseException:
        discard_destination(dest, created)
        raise
    return SnapshotManifest(
        source=ESKLP_SOURCE,
        version=version,
        sha256=result.sha256,
        retrieved_at=retrieved_at,
        url=url,
    )
