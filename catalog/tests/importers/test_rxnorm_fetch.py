"""Fetching the RxNorm Prescribable zip through ``httpx.MockTransport`` (no network)."""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from pathlib import Path

import httpx
import pytest

from catalog.importers.archive import ArchiveRejected
from catalog.importers.base import ImporterError
from catalog.importers.rxnorm import RxNormImporter
from tests.importers.test_rxnorm import RRF
from tests.importers.zip_support import make_zip

NOW = datetime(2026, 11, 1, tzinfo=UTC)
CURRENT = "https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_current.zip"
DATED = "https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_11022026.zip"
FULLWIDTH_RELEASE = "".join(chr(0xFF10 + int(d)) for d in "11022026")
ARCHIVE = make_zip({f"rrf/{p.name}": p.read_bytes() for p in RRF.glob("*.RRF")})


def _importer(
    archive: bytes = ARCHIVE, requested: list[str] | None = None, **options: object
) -> RxNormImporter:
    def handler(request: httpx.Request) -> httpx.Response:
        if requested is not None:
            requested.append(str(request.url))
        return httpx.Response(200, content=archive)

    return RxNormImporter(transport=httpx.MockTransport(handler), now=lambda: NOW, **options)  # type: ignore[arg-type]


def test_fetch_extracts_the_release_and_reports_the_archive_checksum(tmp_path: Path) -> None:
    requested: list[str] = []
    dest = tmp_path / "out"

    manifest = _importer(requested=requested).fetch(dest)

    assert requested == [CURRENT]
    assert (dest / "rrf" / "RXNCONSO.RRF").is_file()
    assert manifest.sha256 == hashlib.sha256(ARCHIVE).hexdigest()
    assert manifest.source == "rxnorm"
    assert manifest.retrieved_at == NOW
    assert manifest.version is None
    assert RxNormImporter().snapshot_version(dest) == "20261102"
    assert list(tmp_path.iterdir()) == [dest]


def test_a_pinned_release_selects_the_dated_archive(tmp_path: Path) -> None:
    requested: list[str] = []

    manifest = _importer(requested=requested, release="11022026").fetch(tmp_path / "out")

    assert requested == [DATED]
    assert manifest.version == "11022026"


@pytest.mark.parametrize(
    "release", ["", "current", "1102202", "../etc", "11-02-2026", FULLWIDTH_RELEASE]
)
def test_an_odd_release_is_refused_before_any_request(tmp_path: Path, release: str) -> None:
    requested: list[str] = []

    with pytest.raises(ImporterError) as caught:
        _importer(requested=requested, release=release).fetch(tmp_path / "out")

    assert caught.value.code == "invalid_release"
    assert requested == []


def test_a_matching_pinned_checksum_is_accepted(tmp_path: Path) -> None:
    pinned = hashlib.sha256(ARCHIVE).hexdigest().upper()

    _importer(expected_sha256=pinned).fetch(tmp_path / "out")

    assert (tmp_path / "out" / "rrf").is_dir()


def test_a_wrong_checksum_keeps_nothing(tmp_path: Path) -> None:
    with pytest.raises(ImporterError) as caught:
        _importer(expected_sha256="0" * 64).fetch(tmp_path / "out")

    assert caught.value.code == "checksum_mismatch"
    assert list(tmp_path.iterdir()) == []


def test_a_malformed_checksum_is_refused(tmp_path: Path) -> None:
    with pytest.raises(ImporterError) as caught:
        _importer(expected_sha256="abc").fetch(tmp_path / "out")

    assert caught.value.code == "invalid_checksum"


def test_an_archive_over_the_cap_is_refused(tmp_path: Path) -> None:
    with pytest.raises(ImporterError) as caught:
        _importer(max_download_bytes=len(ARCHIVE) - 1).fetch(tmp_path / "out")

    assert caught.value.code == "download_too_large"
    assert list(tmp_path.iterdir()) == []


def test_zip_slip_and_archives_without_concepts_leave_nothing(tmp_path: Path) -> None:
    with pytest.raises(ArchiveRejected):
        _importer(archive=make_zip({"../evil.RRF": b"x"})).fetch(tmp_path / "out")
    with pytest.raises(ImporterError) as caught:
        _importer(archive=make_zip({"rrf/RXNREL.RRF": b"x"})).fetch(tmp_path / "out2")

    assert caught.value.code == "invalid_download"
    assert list(tmp_path.iterdir()) == []


def test_a_redirect_to_another_host_is_refused(tmp_path: Path) -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": "https://evil.example.invalid/x.zip"})

    importer = RxNormImporter(transport=httpx.MockTransport(handler))

    with pytest.raises(ImporterError) as caught:
        importer.fetch(tmp_path / "out")

    assert caught.value.code == "fetch_host_not_allowed"
