"""The importer CLI with the real sources of milestone 4.4 (no network: a mock transport)."""

from __future__ import annotations

import asyncio
import hashlib
import json
from pathlib import Path

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.importers import cli
from tests.conftest import make_settings
from tests.importers.support import rows
from tests.importers.test_openfda_ndc import SNAPSHOT as OPENFDA
from tests.importers.test_rxnorm import RRF
from tests.importers.test_rxnorm import SNAPSHOT as RXNORM
from tests.importers.zip_support import make_zip

ARCHIVE = make_zip({f"rrf/{p.name}": p.read_bytes() for p in RRF.glob("*.RRF")})


async def _main(argv: list[str], transport: httpx.BaseTransport | None = None) -> int:
    return await asyncio.to_thread(cli.main, argv, make_settings(), transport)


async def test_run_loads_rxnorm_then_openfda(engine: AsyncEngine, clean_catalog: None) -> None:
    assert await _main(["run", "--source", "rxnorm", "--snapshot", str(RXNORM)]) == 0
    assert await _main(["run", "--source", "openfda_ndc", "--snapshot", str(OPENFDA)]) == 0

    found = await rows(engine, "SELECT source, status FROM catalog.import_runs ORDER BY source")
    assert [tuple(r) for r in found] == [("openfda_ndc", "succeeded"), ("rxnorm", "succeeded")]


async def test_fetch_rxnorm_with_a_pinned_checksum_and_release(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    requested: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested.append(request.url.path)
        return httpx.Response(200, content=ARCHIVE)

    digest = hashlib.sha256(ARCHIVE).hexdigest()
    code = await _main(
        [
            "fetch",
            "--source",
            "rxnorm",
            "--out",
            str(tmp_path / "o"),
            "--release",
            "11022026",
            "--expect-sha256",
            digest,
        ],
        httpx.MockTransport(handler),
    )

    assert code == 0
    assert requested == ["/rxnorm/RxNorm_full_prescribe_11022026.zip"]
    # Logging may share stdout; the summary is the last line.
    assert json.loads(capsys.readouterr().out.splitlines()[-1])["sha256"] == digest


async def test_a_wrong_pinned_checksum_exits_with_its_code(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    transport = httpx.MockTransport(lambda _: httpx.Response(200, content=ARCHIVE))

    code = await _main(
        ["fetch", "--source", "rxnorm", "--out", str(tmp_path / "o"), "--expect-sha256", "0" * 64],
        transport,
    )

    assert code == cli.EXIT_FAILED
    assert "checksum_mismatch" in capsys.readouterr().err
    assert not (tmp_path / "o").exists()


@pytest.mark.parametrize("option", [["--release", "11022026"], ["--expect-sha256", "0" * 64]])
async def test_rxnorm_only_options_are_a_usage_error_for_other_sources(
    capsys: pytest.CaptureFixture[str], tmp_path: Path, option: list[str]
) -> None:
    code = await _main(["fetch", "--source", "openfda_ndc", "--out", str(tmp_path / "o"), *option])

    assert code == cli.EXIT_USAGE
    assert "option_not_supported" in capsys.readouterr().err
