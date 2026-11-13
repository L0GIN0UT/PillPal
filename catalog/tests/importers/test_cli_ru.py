"""The importer CLI with the RU sources of milestone 4.4b: flags are checked by both commands,
fetch takes the operator's URL, and nothing prints record text."""

from __future__ import annotations

import asyncio
import hashlib
import json
from pathlib import Path

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.config import Settings
from catalog.importers import cli
from tests.conftest import make_settings
from tests.importers import ru_data
from tests.importers.support import rows

ESKLP_URL = "https://esklp.egisz.rosminzdrav.ru/files/full.xlsx"
RZN_URL = "https://roszdravnadzor.gov.ru/opendata/recalls.csv"


async def _main(
    argv: list[str], settings: Settings, transport: httpx.BaseTransport | None = None
) -> int:
    return await asyncio.to_thread(cli.main, argv, settings, transport)


class _Recorder:
    """A transport that answers with ``body`` and remembers the requested URLs."""

    def __init__(self, body: bytes) -> None:
        self.urls: list[str] = []
        self.transport = httpx.MockTransport(self._handle)
        self._body = body

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.urls.append(str(request.url))
        return httpx.Response(200, content=self._body)


def _esklp_snapshot(tmp_path: Path) -> Path:
    folder = tmp_path / "esklp"
    folder.mkdir()
    (folder / "esklp.xml").write_text(ru_data.esklp_xml(), encoding="utf-8")
    return folder


@pytest.mark.parametrize("source", ["esklp", "grls_manual"])
async def test_run_and_fetch_refuse_while_the_flag_is_off(
    source: str,
    clean_catalog: None,
    engine: AsyncEngine,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    recorder = _Recorder(b"x")
    settings = make_settings()

    run = await _main(["run", "--source", source, "--snapshot", str(tmp_path)], settings)
    url = ["--url", ESKLP_URL] if source == "esklp" else []
    fetch = await _main(
        ["fetch", "--source", source, "--out", str(tmp_path / "out"), *url],
        settings,
        recorder.transport,
    )

    assert (run, fetch) == (cli.EXIT_REFUSED, cli.EXIT_REFUSED)
    assert capsys.readouterr().err.count("importer_disabled") == 2
    assert recorder.urls == []
    assert (
        await rows(engine, "SELECT count(*) FROM catalog.import_runs WHERE source <> 'consensus'")
    )[0][0] == 0


async def test_esklp_runs_when_the_flag_is_on_and_prints_counts_only(
    clean_catalog: None,
    engine: AsyncEngine,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    settings = make_settings(importer_esklp_enabled=True)

    code = await _main(
        ["run", "--source", "esklp", "--snapshot", str(_esklp_snapshot(tmp_path))], settings
    )

    assert code == 0
    captured = capsys.readouterr()
    assert json.loads(captured.out.splitlines()[-1])["status"] == "succeeded"
    assert "Тестамол" not in captured.out + captured.err
    assert "4600000000015" not in captured.out + captured.err
    found = await rows(engine, "SELECT count(*) FROM catalog.products WHERE market = 'ru'")
    assert found[0][0] == 6


async def test_fetch_esklp_takes_the_operators_url_and_a_pinned_checksum(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    body = ru_data.esklp_xlsx(tmp_path / "src.xlsx").read_bytes()
    recorder = _Recorder(body)
    digest = hashlib.sha256(body).hexdigest()

    code = await _main(
        [
            "fetch",
            "--source",
            "esklp",
            "--out",
            str(tmp_path / "out"),
            "--url",
            ESKLP_URL,
            "--expect-sha256",
            digest,
        ],
        make_settings(importer_esklp_enabled=True),
        recorder.transport,
    )

    assert code == 0
    assert recorder.urls == [ESKLP_URL]
    assert (tmp_path / "out" / "esklp.xlsx").is_file()
    assert json.loads(capsys.readouterr().out.splitlines()[-1])["sha256"] == digest


async def test_fetch_without_a_url_is_reported_by_code(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    code = await _main(
        ["fetch", "--source", "esklp", "--out", str(tmp_path / "o")],
        make_settings(importer_esklp_enabled=True),
    )

    assert code == cli.EXIT_FAILED
    assert "url_required" in capsys.readouterr().err


async def test_fetch_roszdravnadzor_follows_the_esklp_flag(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    recorder = _Recorder(ru_data.rzn_csv())

    code = await _main(
        ["fetch", "--source", "ru_roszdravnadzor", "--out", str(tmp_path / "o"), "--url", RZN_URL],
        make_settings(importer_esklp_enabled=True),
        recorder.transport,
    )

    assert code == 0
    assert recorder.urls == [RZN_URL]
    assert (tmp_path / "o" / "recalls.csv").is_file()


async def test_fetch_of_grls_is_never_possible(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    recorder = _Recorder(b"x")

    code = await _main(
        ["fetch", "--source", "grls_manual", "--out", str(tmp_path / "o")],
        make_settings(importer_grls_enabled=True),
        recorder.transport,
    )

    assert code == cli.EXIT_FAILED
    assert "fetch_not_supported" in capsys.readouterr().err
    assert recorder.urls == []


@pytest.mark.parametrize(
    "extra",
    [
        ["--source", "rxnorm", "--url", ESKLP_URL],
        ["--source", "esklp", "--release", "11022026"],
        ["--source", "openfda_ndc", "--expect-sha256", "0" * 64],
    ],
)
async def test_options_that_do_not_belong_to_a_source_are_usage_errors(
    extra: list[str], capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    code = await _main(
        ["fetch", "--out", str(tmp_path / "o"), *extra], make_settings(importer_esklp_enabled=True)
    )

    assert code == cli.EXIT_USAGE
    assert "option_not_supported" in capsys.readouterr().err


async def test_a_grls_run_reports_unmatched_links_as_a_warning(
    clean_catalog: None, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    folder = tmp_path / "grls"
    folder.mkdir()
    ru_data.grls_xlsx(folder / "export.xlsx")

    code = await _main(
        ["run", "--source", "grls_manual", "--snapshot", str(folder)],
        make_settings(importer_grls_enabled=True),
    )

    assert code == 0
    err = capsys.readouterr().err
    assert "package_links_unmatched=4" in err
    assert "ЛП-" not in err


async def test_roszdravnadzor_is_refused_while_the_esklp_flag_is_off(
    clean_catalog: None, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    recorder = _Recorder(b"x")

    code = await _main(
        ["fetch", "--source", "ru_roszdravnadzor", "--out", str(tmp_path / "o"), "--url", RZN_URL],
        make_settings(),
        recorder.transport,
    )

    assert code == cli.EXIT_REFUSED
    assert "importer_disabled" in capsys.readouterr().err
    assert recorder.urls == []
