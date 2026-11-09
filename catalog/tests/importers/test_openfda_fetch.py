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


def _two_partitions(
    members: dict[str, bytes] | None = None, max_snapshot_bytes: int | None = None
) -> OpenFdaNdcImporter:
    names = ["drug-ndc-0001-of-0002.json", "drug-ndc-0002-of-0002.json"]
    urls = [f"https://download.open.fda.gov/drug/ndc/{n}.zip" for n in names]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "api.fda.gov":
            return httpx.Response(200, json=_index(files=urls))
        name = request.url.path.rsplit("/", 1)[-1].removesuffix(".zip")
        return httpx.Response(200, content=make_zip(members or {name: DATA}))

    options = {} if max_snapshot_bytes is None else {"max_snapshot_bytes": max_snapshot_bytes}
    return OpenFdaNdcImporter(transport=httpx.MockTransport(handler), now=lambda: NOW, **options)


def test_every_partition_arrives_under_its_own_name(tmp_path: Path) -> None:
    _two_partitions().fetch(tmp_path / "out")

    assert sorted(p.name for p in (tmp_path / "out").iterdir()) == [
        "drug-ndc-0001-of-0002.json",
        "drug-ndc-0002-of-0002.json",
    ]


def test_a_partition_that_holds_another_file_is_refused(tmp_path: Path) -> None:
    importer = _two_partitions(members={"drug-ndc-0001-of-0002.json": DATA})  # twice the same

    with pytest.raises(ImporterError) as caught:
        importer.fetch(tmp_path / "out")

    assert caught.value.code == "invalid_download"
    assert list(tmp_path.iterdir()) == []


def test_a_partition_with_extra_members_is_refused(tmp_path: Path) -> None:
    importer = _two_partitions(
        members={"drug-ndc-0001-of-0002.json": DATA, "drug-ndc-0002-of-0002.json": DATA}
    )

    with pytest.raises(ArchiveRejected) as caught:
        importer.fetch(tmp_path / "out")

    assert caught.value.code == "archive_too_large"
    assert list(tmp_path.iterdir()) == []


def test_the_whole_snapshot_has_a_disk_budget(tmp_path: Path) -> None:
    importer = _two_partitions(max_snapshot_bytes=len(DATA) + len(DATA) // 2)

    with pytest.raises(ArchiveRejected) as caught:
        importer.fetch(tmp_path / "out")

    assert caught.value.code == "archive_too_large"
    assert list(tmp_path.iterdir()) == []


def test_an_unexpected_error_while_fetching_leaves_nothing_behind(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def broken(archive: Path, dest: Path, *args: object) -> None:
        dest.mkdir(exist_ok=True)
        (dest / "partial.json").write_text("{", encoding="utf-8")
        raise OSError("disk full")

    monkeypatch.setattr("catalog.importers.openfda_fetch.safe_extract_zip", broken)

    with pytest.raises(OSError, match="disk full"):
        _importer().fetch(tmp_path / "out")

    assert list(tmp_path.iterdir()) == []


def test_a_partial_snapshot_is_refused_when_it_is_parsed(tmp_path: Path) -> None:
    dest = tmp_path / "snap"
    dest.mkdir()
    (dest / "drug-ndc-0001-of-0003.json").write_bytes(DATA)
    (dest / "drug-ndc-0003-of-0003.json").write_bytes(DATA)

    with pytest.raises(ImporterError) as caught:
        list(OpenFdaNdcImporter().parse(dest))

    assert caught.value.code == "snapshot_incomplete"
    with pytest.raises(ImporterError):
        OpenFdaNdcImporter().snapshot_version(dest)


def test_mixed_partition_counts_are_refused(tmp_path: Path) -> None:
    dest = tmp_path / "snap"
    dest.mkdir()
    (dest / "drug-ndc-0001-of-0002.json").write_bytes(DATA)
    (dest / "drug-ndc-0002-of-0003.json").write_bytes(DATA)

    with pytest.raises(ImporterError) as caught:
        list(OpenFdaNdcImporter().parse(dest))

    assert caught.value.code == "snapshot_incomplete"
