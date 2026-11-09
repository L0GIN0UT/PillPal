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

from catalog.importers.archive import ArchiveLimits, safe_extract_zip
from catalog.importers.base import ImporterError, SnapshotManifest, snapshot_sha256
from catalog.importers.fetch import (
    discard_destination,
    download_file,
    get_json,
    new_client,
    prepare_destination,
)

INDEX_URL = "https://api.fda.gov/download.json"
ALLOWED_HOSTS = frozenset({"api.fda.gov", "download.open.fda.gov"})
MAX_INDEX_BYTES = 8 * 1024 * 1024
MAX_PARTITION_BYTES = 1024**3
MAX_PARTITIONS = 20
MAX_SNAPSHOT_BYTES = 8 * 1024**3  # disk budget of all partitions together
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


def _fetch_partitions(
    client: httpx.Client,
    urls: list[str],
    dest: Path,
    tmp: Path,
    max_partition_bytes: int,
    max_snapshot_bytes: int,
) -> None:
    """Each partition must yield exactly its own file; the sum of all stays under the budget."""
    remaining = max_snapshot_bytes
    for number, url in enumerate(urls):
        expected = url.rsplit("/", 1)[-1].removesuffix(".zip")
        archive = tmp / f"{number}.zip"
        download_file(
            client, url, archive, max_bytes=max_partition_bytes, allowed_hosts=ALLOWED_HOSTS
        )
        part = tmp / f"part{number}"
        limits = ArchiveLimits(
            max_files=1,
            max_total_bytes=remaining,
            max_file_bytes=min(MAX_EXTRACTED_FILE_BYTES, remaining),
        )
        safe_extract_zip(archive, part, limits)
        archive.unlink()
        if [p.name for p in part.iterdir()] != [expected] or not (part / expected).is_file():
            raise ImporterError("invalid_download")
        remaining -= (part / expected).stat().st_size
        dest.mkdir(parents=True, exist_ok=True)
        shutil.move(str(part / expected), str(dest / expected))


def fetch_snapshot(
    dest: Path,
    *,
    transport: httpx.BaseTransport | None,
    retrieved_at: datetime,
    max_partition_bytes: int = MAX_PARTITION_BYTES,
    max_snapshot_bytes: int = MAX_SNAPSHOT_BYTES,
    index_url: str = INDEX_URL,
) -> SnapshotManifest:
    """Download every partition into ``dest`` (which must not hold files yet). A partial
    snapshot would make the next run withdraw every product it lacks, so on any failure,
    including an unexpected one, nothing is left behind."""
    created = prepare_destination(dest)
    try:
        with new_client(transport) as client, tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
            index = get_json(
                client, index_url, max_bytes=MAX_INDEX_BYTES, allowed_hosts=ALLOWED_HOSTS
            )
            urls, version = _partition_urls(index)
            _fetch_partitions(
                client, urls, dest, Path(tmp), max_partition_bytes, max_snapshot_bytes
            )
    except BaseException:
        discard_destination(dest, created)
        raise
    return SnapshotManifest(
        source=SOURCE,
        version=version,
        sha256=snapshot_sha256(dest),
        retrieved_at=retrieved_at,
        url=index_url,
    )
