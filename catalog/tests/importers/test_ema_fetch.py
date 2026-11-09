"""Fetching the EMA workbook through ``httpx.MockTransport`` (no network), and the CLI wiring."""

from __future__ import annotations

import asyncio
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.importers import cli
from catalog.importers.base import ImporterError
from catalog.importers.ema import EmaImporter
from catalog.importers.ema_fetch import DEFAULT_URL
from tests.conftest import make_settings
from tests.importers import ema_data
from tests.importers.support import rows
from tests.importers.xlsx_support import build_xlsx
from tests.importers.zip_support import make_zip

NOW = datetime(2026, 11, 1, tzinfo=UTC)
URL = "https://www.ema.europa.eu/en/documents/report/other.xlsx"


def _body(tmp_path: Path) -> bytes:
    return ema_data.workbook(tmp_path / "src.xlsx").read_bytes()


def _importer(
    body: bytes,
    requested: list[str] | None = None,
    url: str | None = URL,
    status: int = 200,
    **options: object,
) -> EmaImporter:
    def handler(request: httpx.Request) -> httpx.Response:
        if requested is not None:
            requested.append(str(request.url))
        return httpx.Response(status, content=body)

    return EmaImporter(
        transport=httpx.MockTransport(handler),
        now=lambda: NOW,
        url=url,
        **options,  # type: ignore[arg-type]
    )


def _code(importer: EmaImporter, folder: Path) -> str:
    with pytest.raises(ImporterError) as caught:
        importer.fetch(folder / "snap")
    assert not (folder / "snap").exists()  # nothing is kept on failure
    return caught.value.code


def test_a_workbook_is_downloaded_and_stored(tmp_path: Path) -> None:
    body = _body(tmp_path)
    dest = tmp_path / "out" / "snap"
    requested: list[str] = []

    manifest = _importer(body, requested).fetch(dest)

    assert requested == [URL]
    assert [p.name for p in dest.iterdir()] == ["ema.xlsx"]
    assert manifest.sha256 == hashlib.sha256(body).hexdigest()
    assert manifest.source == "ema"
    assert manifest.retrieved_at == NOW
    assert EmaImporter().snapshot_version(dest) == "2026-10-01"


def test_without_a_url_the_public_default_is_requested(tmp_path: Path) -> None:
    requested: list[str] = []
    _importer(_body(tmp_path), requested, url=None).fetch(tmp_path / "snap")
    assert requested == [DEFAULT_URL]


def test_the_url_is_checked_before_any_request(tmp_path: Path) -> None:
    requested: list[str] = []
    http = "http://www.ema.europa.eu/x.xlsx"
    assert _code(_importer(b"", requested, url=http), tmp_path / "a") == "fetch_insecure_url"
    other = "https://example.invalid/ema.xlsx"
    assert _code(_importer(b"", requested, url=other), tmp_path / "b") == "fetch_host_not_allowed"
    with_user = "https://user:pw@www.ema.europa.eu/x"
    got = _code(_importer(b"", requested, url=with_user), tmp_path / "c")
    assert got == "fetch_host_not_allowed"
    assert requested == []


def test_a_redirect_to_another_host_is_refused(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": "https://example.invalid/steal"})

    importer = EmaImporter(transport=httpx.MockTransport(handler), url=URL, now=lambda: NOW)
    assert _code(importer, tmp_path / "out") == "fetch_host_not_allowed"


def test_a_pinned_checksum_is_enforced_and_validated(tmp_path: Path) -> None:
    body = _body(tmp_path)
    assert _code(_importer(body, expected_sha256="0" * 64), tmp_path / "a") == "checksum_mismatch"
    assert _code(_importer(body, expected_sha256="xyz"), tmp_path / "b") == "invalid_checksum"
    ok = _importer(body, expected_sha256=hashlib.sha256(body).hexdigest())
    assert ok.fetch(tmp_path / "c").sha256 == hashlib.sha256(body).hexdigest()


def test_the_download_size_is_capped(tmp_path: Path) -> None:
    importer = _importer(_body(tmp_path), max_download_bytes=100)
    assert _code(importer, tmp_path / "out") == "download_too_large"


def test_a_failed_status_is_refused(tmp_path: Path) -> None:
    assert _code(_importer(b"x", status=503), tmp_path / "out") == "fetch_failed"


@pytest.mark.parametrize(
    ("body", "code"),
    [
        (b"<html><body>Cookie wall</body></html>", "invalid_download"),
        (b"", "invalid_download"),
        (b"PK\x03\x04 not really a zip", "invalid_download"),
        (make_zip({"readme.txt": b"hello"}), "invalid_download"),
    ],
)
def test_a_download_that_is_not_a_workbook_is_refused(
    tmp_path: Path, body: bytes, code: str
) -> None:
    assert _code(_importer(body), tmp_path / "out") == code


def test_a_workbook_that_is_not_the_list_is_refused_and_removed(tmp_path: Path) -> None:
    build_xlsx(tmp_path / "w.xlsx", {"s": [["a", "b"], ["1", "2"]]})
    body = (tmp_path / "w.xlsx").read_bytes()
    assert _code(_importer(body), tmp_path / "out") == "missing_columns"


def test_a_list_without_medicines_is_refused_and_removed(tmp_path: Path) -> None:
    ema_data.workbook(tmp_path / "e.xlsx", [])
    assert (
        _code(_importer((tmp_path / "e.xlsx").read_bytes()), tmp_path / "out") == "empty_snapshot"
    )


def test_a_destination_with_files_is_refused(tmp_path: Path) -> None:
    dest = tmp_path / "snap"
    dest.mkdir()
    (dest / "keep.txt").write_text("x")
    with pytest.raises(ImporterError) as caught:
        _importer(_body(tmp_path)).fetch(dest)
    assert caught.value.code == "destination_not_empty"
    assert (dest / "keep.txt").exists()


async def _main(argv: list[str], transport: httpx.BaseTransport | None = None) -> int:
    return await asyncio.to_thread(cli.main, argv, make_settings(), transport)


async def test_the_cli_fetches_and_runs_ema(
    engine: AsyncEngine,
    clean_catalog: None,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    body = _body(tmp_path)
    requested: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested.append(str(request.url))
        return httpx.Response(200, content=body)

    out = tmp_path / "o"
    transport = httpx.MockTransport(handler)
    assert await _main(["fetch", "--source", "ema", "--out", str(out)], transport) == 0
    assert requested == [DEFAULT_URL]
    digest = json.loads(capsys.readouterr().out.splitlines()[-1])["sha256"]
    assert digest == hashlib.sha256(body).hexdigest()

    assert await _main(["run", "--source", "ema", "--snapshot", str(out)]) == 0

    found = await rows(engine, "SELECT source, status FROM catalog.import_runs")
    assert [tuple(r) for r in found] == [("ema", "succeeded")]
