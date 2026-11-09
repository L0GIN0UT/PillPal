"""Download of the openFDA ``drug-ndc`` bulk files.

``https://api.fda.gov/download.json`` lists the partitions (zip files, one JSON file each) and the
export date. Each partition is downloaded under a byte cap and extracted with the archive guards
(zip-slip, bombs). openFDA publishes no checksums, so the manifest reports the sha256 of the
resulting snapshot directory, the same value ``import_runs`` records for a run.
"""

from __future__ import annotations

import re
import shutil
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx

from catalog.importers.archive import ArchiveLimits, ArchiveRejected, safe_extract_zip
from catalog.importers.base import ImporterError, SnapshotManifest, snapshot_sha256
from catalog.importers.fetch import download_file, get_json, new_client

INDEX_URL = "https://api.fda.gov/download.json"
ALLOWED_HOSTS = frozenset({"api.fda.gov", "download.open.fda.gov"})
MAX_INDEX_BYTES = 8 * 1024 * 1024
MAX_PARTITION_BYTES = 1024**3
MAX_PARTITIONS = 20
MAX_EXTRACTED_FILE_BYTES = 4 * 1024**3
_PARTITION_NAME = re.compile(r"drug-ndc-\d{4}-of-\d{4}\.json\.zip", re.ASCII)
_EXPORT_DATE = re.compile(r"\d{4}-\d{2}-\d{2}", re.ASCII)
SOURCE = "openfda_ndc"


def _bad_index() -> ImporterError:
    return ImporterError("invalid_download")


def _partition_urls(index: Any) -> tuple[list[str], str | None]:
    try:
        ndc = index["results"]["drug"]["ndc"]
        files = [p["file"] for p in ndc["partitions"]]
        exported = ndc.get("export_date")
    except (KeyError, TypeError):
        raise _bad_index() from None
    names = [f.rsplit("/", 1)[-1] if isinstance(f, str) else "" for f in files]
    if not 0 < len(files) <= MAX_PARTITIONS or len(set(names)) != len(names):
        raise _bad_index()
    if any(_PARTITION_NAME.fullmatch(name) is None for name in names):
        raise _bad_index()
    version = exported if isinstance(exported, str) and _EXPORT_DATE.fullmatch(exported) else None
    return files, version


def fetch_snapshot(
    dest: Path,
    *,
    transport: httpx.BaseTransport | None,
    retrieved_at: datetime,
    max_partition_bytes: int = MAX_PARTITION_BYTES,
    index_url: str = INDEX_URL,
) -> SnapshotManifest:
    """Download every partition into ``dest`` (which must not hold files yet)."""
    if dest.exists() and any(dest.iterdir()):
        raise ImporterError("destination_not_empty")
    dest.parent.mkdir(parents=True, exist_ok=True)
    limits = ArchiveLimits(max_files=MAX_PARTITIONS, max_file_bytes=MAX_EXTRACTED_FILE_BYTES)
    created = not dest.exists()
    try:
        with new_client(transport) as client, tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
            index = get_json(
                client, index_url, max_bytes=MAX_INDEX_BYTES, allowed_hosts=ALLOWED_HOSTS
            )
            urls, version = _partition_urls(index)
            for number, url in enumerate(urls):
                archive = Path(tmp) / f"{number}.zip"
                download_file(
                    client, url, archive, max_bytes=max_partition_bytes, allowed_hosts=ALLOWED_HOSTS
                )
                safe_extract_zip(archive, dest, limits)
                archive.unlink()
    except (ImporterError, ArchiveRejected):
        _discard(dest, created)
        raise
    if not any(dest.glob("drug-ndc-*.json")):
        _discard(dest, created)
        raise ImporterError("invalid_download")
    return SnapshotManifest(
        source=SOURCE,
        version=version,
        sha256=snapshot_sha256(dest),
        retrieved_at=retrieved_at,
        url=index_url,
    )


def _discard(dest: Path, created: bool) -> None:
    if created:
        shutil.rmtree(dest, ignore_errors=True)
    else:
        for child in dest.iterdir():
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink()
