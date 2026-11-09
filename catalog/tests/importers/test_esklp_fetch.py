"""Fetching the ESKLP file the operator names, through ``httpx.MockTransport`` (no network)."""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from pathlib import Path

import httpx
import pytest

from catalog.importers.archive import ArchiveRejected
from catalog.importers.base import ImporterDisabled, ImporterError
from catalog.importers.esklp import EsklpImporter
from tests.importers import ru_data
from tests.importers.xlsx_support import build_xlsx
from tests.importers.zip_support import make_zip

NOW = datetime(2026, 11, 1, tzinfo=UTC)
URL = "https://esklp.egisz.rosminzdrav.ru/files/esklp-full.xlsx"


def _workbook(tmp_path: Path) -> bytes:
    return ru_data.esklp_xlsx(tmp_path / "src.xlsx").read_bytes()


def _importer(
    body: bytes,
    requested: list[str] | None = None,
    url: str | None = URL,
    status: int = 200,
    **options: object,
) -> EsklpImporter:
    def handler(request: httpx.Request) -> httpx.Response:
        if requested is not None:
            requested.append(str(request.url))
        return httpx.Response(status, content=body)

    return EsklpImporter(
        enabled=True,
        transport=httpx.MockTransport(handler),
        now=lambda: NOW,
        url=url,
        **options,  # type: ignore[arg-type]
    )


def _code(importer: EsklpImporter, folder: Path) -> str:
    dest = folder / "snap"
    with pytest.raises((ImporterError, ArchiveRejected)) as caught:
        importer.fetch(dest)
    assert not dest.exists()  # nothing is kept
    # not even a temporary directory next to it
    assert not folder.exists() or list(folder.iterdir()) == []
    return caught.value.code


def test_a_workbook_is_stored_and_reported(tmp_path: Path) -> None:
    body = _workbook(tmp_path)
    dest = tmp_path / "out" / "snap"
    requested: list[str] = []

    manifest = _importer(body, requested).fetch(dest)

    assert requested == [URL]
    assert [p.name for p in dest.iterdir()] == ["esklp.xlsx"]
    assert manifest.sha256 == hashlib.sha256(body).hexdigest()
    assert manifest.source == "esklp"
    assert manifest.version == "2026-10-01"
    assert manifest.retrieved_at == NOW
    assert EsklpImporter(enabled=True).snapshot_version(dest) == "2026-10-01"


def test_a_zip_of_xml_files_is_extracted(tmp_path: Path) -> None:
    body = make_zip({"esklp/part1.xml": ru_data.esklp_xml().encode()})

    manifest = _importer(body).fetch(tmp_path / "out")

    assert (tmp_path / "out" / "esklp" / "part1.xml").is_file()
    assert manifest.version == "2026-10-01"


def test_a_bare_xml_file_is_stored(tmp_path: Path) -> None:
    _importer(ru_data.esklp_xml().encode()).fetch(tmp_path / "out")
    assert [p.name for p in (tmp_path / "out").iterdir()] == ["esklp.xml"]


def test_the_url_comes_from_the_operator_and_is_checked_before_any_request(tmp_path: Path) -> None:
    requested: list[str] = []
    assert _code(_importer(b"", requested, url=None), tmp_path / "a") == "url_required"
    http = "http://esklp.egisz.rosminzdrav.ru/x.xlsx"
    assert _code(_importer(b"", requested, url=http), tmp_path / "b") == "fetch_insecure_url"
    other = "https://example.invalid/esklp.xlsx"
    assert _code(_importer(b"", requested, url=other), tmp_path / "c") == "fetch_host_not_allowed"
    with_user = "https://user:pw@esklp.egisz.rosminzdrav.ru/x"
    assert (
        _code(_importer(b"", requested, url=with_user), tmp_path / "d") == "fetch_host_not_allowed"
    )
    assert requested == []


def test_a_redirect_to_another_host_is_refused(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": "https://example.invalid/steal"})

    importer = EsklpImporter(
        enabled=True, transport=httpx.MockTransport(handler), url=URL, now=lambda: NOW
    )
    assert _code(importer, tmp_path / "out") == "fetch_host_not_allowed"


@pytest.mark.parametrize(
    ("body", "code"),
    [
        (b"<html><body>Login required</body></html>", "invalid_download"),
        (b"", "invalid_download"),
        (b"PK\x03\x04 not really a zip", "invalid_download"),
        (make_zip({"readme.txt": b"hello"}), "invalid_download"),
        (make_zip({"../evil.xml": b"<x/>"}), "unsafe_archive_path"),
        (b'<?xml version="1.0"?><esklp></esklp>', "empty_snapshot"),
    ],
)
def test_a_download_that_is_not_a_snapshot_is_refused_and_removed(
    tmp_path: Path, body: bytes, code: str
) -> None:
    assert _code(_importer(body), tmp_path / "out") == code


def test_a_workbook_without_the_columns_is_refused_and_removed(tmp_path: Path) -> None:
    build_xlsx(tmp_path / "w.xlsx", {"s": [["a", "b"], ["1", "2"]]})
    body = (tmp_path / "w.xlsx").read_bytes()
    (tmp_path / "w.xlsx").unlink()

    assert _code(_importer(body), tmp_path / "out") == "missing_columns"


def test_a_truncated_xml_download_is_refused_and_removed(tmp_path: Path) -> None:
    body = ru_data.esklp_xml().encode()[:700]
    assert _code(_importer(body), tmp_path / "out") == "invalid_snapshot"


def test_http_errors_and_oversized_downloads_are_refused(tmp_path: Path) -> None:
    assert _code(_importer(b"x", status=403), tmp_path / "a") == "fetch_failed"

    small = _importer(_workbook(tmp_path), max_download_bytes=100)
    assert _code(small, tmp_path / "b") == "download_too_large"


def test_a_pinned_checksum_must_match(tmp_path: Path) -> None:
    body = _workbook(tmp_path)
    digest = hashlib.sha256(body).hexdigest()

    _importer(body, expected_sha256=digest.upper()).fetch(tmp_path / "ok")
    assert _code(_importer(body, expected_sha256="0" * 64), tmp_path / "bad") == "checksum_mismatch"
    assert _code(_importer(body, expected_sha256="nope"), tmp_path / "bad2") == "invalid_checksum"


def test_a_non_empty_destination_is_refused(tmp_path: Path) -> None:
    dest = tmp_path / "out"
    dest.mkdir()
    (dest / "keep.txt").write_text("x")
    with pytest.raises(ImporterError) as caught:
        _importer(b"x").fetch(dest)
    assert caught.value.code == "destination_not_empty"
    assert (dest / "keep.txt").read_text() == "x"


def test_a_disabled_importer_makes_no_request(tmp_path: Path) -> None:
    requested: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested.append(str(request.url))
        return httpx.Response(200)

    importer = EsklpImporter(enabled=False, transport=httpx.MockTransport(handler), url=URL)
    with pytest.raises(ImporterDisabled):
        importer.fetch(tmp_path / "out")
    assert requested == []
