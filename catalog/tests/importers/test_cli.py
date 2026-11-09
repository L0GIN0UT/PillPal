"""The importer CLI: ``python -m catalog.importers run|fetch``. It runs in a worker thread because
the CLI owns its event loop, as it does when started from a shell."""

from __future__ import annotations

import asyncio
import subprocess
import sys
from pathlib import Path

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.config import Settings
from catalog.importers import cli
from tests.conftest import make_settings
from tests.importers.support import V1, rows

CATALOG_DIR = Path(__file__).resolve().parents[2]


async def _main(argv: list[str], settings: Settings) -> int:
    return await asyncio.to_thread(cli.main, argv, settings)


async def test_run_loads_the_fixture_snapshot(
    engine: AsyncEngine, clean_catalog: None, capsys: pytest.CaptureFixture[str]
) -> None:
    code = await _main(["run", "--source", "fixture", "--snapshot", str(V1)], make_settings())

    assert code == 0
    found = await rows(engine, "SELECT status, source_version FROM catalog.import_runs")
    assert [tuple(r) for r in found] == [("succeeded", "2026-01")]
    out = capsys.readouterr().out
    assert "succeeded" in out
    # The summary carries counts only: never names, keys or GTINs.
    assert "Testamol" not in out
    assert "04607012345677" not in out


async def test_run_can_skip_withdrawing(engine: AsyncEngine, clean_catalog: None) -> None:
    await _main(["run", "--source", "fixture", "--snapshot", str(V1)], make_settings())
    v2 = V1.parent / "v2"

    code = await _main(
        ["run", "--source", "fixture", "--snapshot", str(v2), "--no-withdraw"], make_settings()
    )

    assert code == 0
    found = await rows(engine, "SELECT count(*) FROM catalog.products WHERE withdrawn_at IS NULL")
    assert found[0][0] == 3


async def test_the_fixture_source_is_refused_in_strict_environments(
    clean_catalog: None, capsys: pytest.CaptureFixture[str]
) -> None:
    settings = make_settings(
        environment="prod",
        admin_tokens="a:" + "1" * 64,
        ingest_tokens="i:" + "2" * 64,
        rate_limit_salt="prod-salt-prod-salt",
    )

    code = await _main(["run", "--source", "fixture", "--snapshot", str(V1)], settings)

    assert code == cli.EXIT_REFUSED
    assert "fixture_source_not_allowed" in capsys.readouterr().err


async def test_a_disabled_importer_exits_with_its_code(
    clean_catalog: None, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    code = await _main(["run", "--source", "esklp", "--snapshot", str(tmp_path)], make_settings())

    assert code == cli.EXIT_REFUSED
    assert "importer_disabled" in capsys.readouterr().err


async def test_an_unknown_source_is_a_usage_error(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    with pytest.raises(SystemExit) as caught:
        await _main(["run", "--source", "nope", "--snapshot", str(tmp_path)], make_settings())

    assert caught.value.code == cli.EXIT_USAGE
    assert "invalid choice" in capsys.readouterr().err


async def test_a_missing_snapshot_directory_is_reported_by_code(
    clean_catalog: None, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    code = await _main(
        ["run", "--source", "fixture", "--snapshot", str(tmp_path / "missing")], make_settings()
    )

    assert code == cli.EXIT_FAILED
    assert "snapshot_not_found" in capsys.readouterr().err


async def test_fetch_of_the_fixture_has_no_network(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    code = await _main(["fetch", "--source", "fixture", "--out", str(tmp_path)], make_settings())

    assert code == cli.EXIT_FAILED
    assert "fetch_not_supported" in capsys.readouterr().err


def test_the_module_entry_point_prints_usage() -> None:
    result = subprocess.run(
        [sys.executable, "-m", "catalog.importers", "--help"],
        cwd=CATALOG_DIR,
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )

    assert result.returncode == 0
    assert "run" in result.stdout
    assert "fetch" in result.stdout
