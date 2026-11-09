"""Download of the RxNorm Prescribable zip from NLM.

The archive is one file, so it can be pinned: ``expected_sha256`` (the checksum the owner took
from NLM or from an earlier fetch) must match or nothing is kept, and the manifest reports the
sha256 of the archive itself. ``release`` (``MMDDYYYY``) selects a dated release; without it the
current one is fetched.
"""

from __future__ import annotations

import re
import tempfile
from datetime import datetime
from pathlib import Path

import httpx

from catalog.importers.archive import safe_extract_zip
from catalog.importers.base import ImporterError, SnapshotManifest
from catalog.importers.fetch import (
    discard_destination,
    download_file,
    new_client,
    prepare_destination,
)

SOURCE = "rxnorm"
ARCHIVE_BASE = "https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_"
ALLOWED_HOSTS = frozenset({"download.nlm.nih.gov"})
MAX_ARCHIVE_BYTES = 2 * 1024**3
RRF_DIR = "rrf"
CONCEPT_FILE = "RXNCONSO.RRF"
_RELEASE = re.compile(r"\d{8}", re.ASCII)
_SHA256 = re.compile(r"[0-9a-fA-F]{64}", re.ASCII)


def find_rrf_dir(snapshot_dir: Path) -> Path:
    """``rrf/`` of an extracted release, or the snapshot directory itself."""
    inner = snapshot_dir / RRF_DIR
    return inner if inner.is_dir() else snapshot_dir


def archive_url(release: str | None) -> str:
    if release is not None and _RELEASE.fullmatch(release) is None:
        raise ImporterError("invalid_release")
    return f"{ARCHIVE_BASE}{release or 'current'}.zip"


def fetch_snapshot(
    dest: Path,
    *,
    transport: httpx.BaseTransport | None,
    retrieved_at: datetime,
    release: str | None,
    expected_sha256: str | None,
    max_bytes: int = MAX_ARCHIVE_BYTES,
) -> SnapshotManifest:
    url = archive_url(release)
    if expected_sha256 is not None and _SHA256.fullmatch(expected_sha256) is None:
        raise ImporterError("invalid_checksum")
    created = prepare_destination(dest)
    try:
        with new_client(transport) as client, tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
            archive = Path(tmp) / "rxnorm.zip"
            result = download_file(
                client,
                url,
                archive,
                max_bytes=max_bytes,
                allowed_hosts=ALLOWED_HOSTS,
                expected_sha256=expected_sha256,
            )
            safe_extract_zip(archive, dest)
        if not (find_rrf_dir(dest) / CONCEPT_FILE).is_file():
            raise ImporterError("invalid_download")
    except BaseException:
        discard_destination(dest, created)
        raise
    return SnapshotManifest(
        source=SOURCE, version=release, sha256=result.sha256, retrieved_at=retrieved_at, url=url
    )
