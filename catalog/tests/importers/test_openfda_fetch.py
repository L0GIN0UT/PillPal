"""Fetching the openFDA bulk files through ``httpx.MockTransport`` (no network)."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
import pytest

from catalog.importers.archive import ArchiveRejected
from catalog.importers.base import ImporterError, snapshot_sha256
from catalog.importers.openfda_ndc import OpenFdaNdcImporter
from tests.importers.test_openfda_ndc import DATA_FILE, SNAPSHOT
from tests.importers.zip_support import make_zip

NOW = datetime(2026, 11, 1, tzinfo=UTC)
PARTITION_URL = "https://download.open.fda.gov/drug/ndc/drug-ndc-0001-of-0001.json.zip"
DATA = (SNAPSHOT / DATA_FILE).read_bytes()


def _index(files: list[Any] | None = None, export_date: Any = "2026-10-30") -> dict[str, Any]:
    partitions = [{"file": f} for f in (files if files is not None else [PARTITION_URL])]
    return {"results": {"drug": {"ndc": {"export_date": export_date, "partitions": partitions}}}}


def _importer(
    index: Any = None, archive: bytes | None = None, max_download_bytes: int = 10**7
) -> OpenFdaNdcImporter:
    body = make_zip({DATA_FILE: DATA}) if archive is None else archive

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "api.fda.gov":
            return httpx.Response(200, json=_index() if index is None else index)
        return httpx.Response(200, content=body)

    return OpenFdaNdcImporter(
        transport=httpx.MockTransport(handler),
        now=lambda: NOW,
        max_download_bytes=max_download_bytes,
    )


def test_fetch_downloads_extracts_and_describes_the_snapshot(tmp_path: Path) -> None:
    dest = tmp_path / "out"

    manifest = _importer().fetch(dest)

    assert (dest / DATA_FILE).read_bytes() == DATA
    assert manifest.source == "openfda_ndc"
    assert manifest.version == "2026-10-30"
    assert manifest.retrieved_at == NOW
    assert manifest.sha256 == snapshot_sha256(dest)
    assert list(tmp_path.iterdir()) == [dest]  # no temporary files left behind
    # The fetched directory is a valid snapshot.
    assert OpenFdaNdcImporter().snapshot_version(dest) == "2026-10-30"


def test_a_partition_over_the_size_cap_is_refused_and_leaves_nothing(tmp_path: Path) -> None:
    dest = tmp_path / "out"

    with pytest.raises(ImporterError) as caught:
        _importer(max_download_bytes=100).fetch(dest)

    assert caught.value.code == "download_too_large"
    assert list(tmp_path.iterdir()) == []


def test_a_zip_slip_member_is_rejected_and_leaves_nothing(tmp_path: Path) -> None:
    evil = make_zip({"../../evil.json": b"{}"})

    with pytest.raises(ArchiveRejected) as caught:
        _importer(archive=evil).fetch(tmp_path / "out")

    assert caught.value.code == "unsafe_archive_path"
    assert list(tmp_path.iterdir()) == []


def test_an_archive_without_a_data_file_is_refused(tmp_path: Path) -> None:
    with pytest.raises(ImporterError) as caught:
        _importer(archive=make_zip({"readme.txt": b"x"})).fetch(tmp_path / "out")

    assert caught.value.code == "invalid_download"
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize(
    "index",
    [
        {},
        {"results": {"drug": {}}},
        _index(files=[]),
        _index(files=[1]),
        _index(files=["https://download.open.fda.gov/drug/ndc/evil.zip"]),
        _index(files=[PARTITION_URL, PARTITION_URL]),
        _index(
            files=[
                f"https://download.open.fda.gov/drug/ndc/drug-ndc-{i:04d}-of-0099.json.zip"
                for i in range(21)
            ]
        ),
    ],
)
def test_a_malformed_index_is_refused(tmp_path: Path, index: Any) -> None:
    with pytest.raises(ImporterError) as caught:
        _importer(index=index).fetch(tmp_path / "out")

    assert caught.value.code == "invalid_download"


def test_a_partition_on_another_host_is_refused(tmp_path: Path) -> None:
    index = _index(files=["https://evil.example.invalid/drug/ndc/drug-ndc-0001-of-0001.json.zip"])

    with pytest.raises(ImporterError) as caught:
        _importer(index=index).fetch(tmp_path / "out")

    assert caught.value.code == "fetch_host_not_allowed"
    assert list(tmp_path.iterdir()) == []


def test_an_unusable_export_date_gives_no_version(tmp_path: Path) -> None:
    manifest = _importer(index=_index(export_date="yesterday")).fetch(tmp_path / "out")

    assert manifest.version is None


def test_a_non_empty_destination_is_never_touched(tmp_path: Path) -> None:
    dest = tmp_path / "out"
    dest.mkdir()
    (dest / "keep.txt").write_text("mine", encoding="utf-8")

    with pytest.raises(ImporterError) as caught:
        _importer().fetch(dest)

    assert caught.value.code == "destination_not_empty"
    assert (dest / "keep.txt").read_text(encoding="utf-8") == "mine"


def test_a_failed_fetch_into_an_existing_empty_directory_leaves_it_empty(tmp_path: Path) -> None:
    dest = tmp_path / "out"
    dest.mkdir()

    with pytest.raises(ImporterError):
        _importer(archive=make_zip({"readme.txt": b"x"})).fetch(dest)

    assert dest.is_dir()
    assert list(dest.iterdir()) == []
