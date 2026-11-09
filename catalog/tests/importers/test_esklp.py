"""The ESKLP importer is a stub in 4.3: it refuses to run unless the owner enabled it (D1)."""

from __future__ import annotations

from pathlib import Path

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.config import Settings
from catalog.importers.base import ImporterDisabled, ImporterError
from catalog.importers.esklp import EsklpImporter
from catalog.importers.loader import run_import
from tests.conftest import TEST_DATABASE_URL, make_settings
from tests.importers.support import rows


def test_the_flags_default_to_off() -> None:
    settings = make_settings()
    assert settings.importer_esklp_enabled is False
    assert settings.importer_grls_enabled is False


def test_the_flags_come_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CATALOG_DATABASE_URL", TEST_DATABASE_URL)
    monkeypatch.setenv("CATALOG_IMPORTER_ESKLP_ENABLED", "true")
    monkeypatch.setenv("CATALOG_IMPORTER_GRLS_ENABLED", "true")
    settings = Settings()  # type: ignore[call-arg]
    assert settings.importer_esklp_enabled is True
    assert settings.importer_grls_enabled is True


def test_the_stub_refuses_every_operation_while_the_flag_is_off(tmp_path: Path) -> None:
    importer = EsklpImporter(enabled=False)
    assert importer.source == "esklp"

    with pytest.raises(ImporterDisabled) as caught:
        importer.ensure_enabled()
    assert caught.value.code == "importer_disabled"
    with pytest.raises(ImporterDisabled):
        importer.fetch(tmp_path)
    with pytest.raises(ImporterDisabled):
        list(importer.parse(tmp_path))


def test_the_enabled_stub_is_not_implemented_yet(tmp_path: Path) -> None:
    importer = EsklpImporter(enabled=True)
    importer.ensure_enabled()  # the flag is the owner's act: no refusal

    with pytest.raises(ImporterError) as caught:
        list(importer.parse(tmp_path))
    assert caught.value.code == "not_implemented"


async def test_a_refused_import_leaves_no_run_behind(
    sessionmaker: async_sessionmaker[AsyncSession], engine: AsyncEngine, tmp_path: Path
) -> None:
    with pytest.raises(ImporterDisabled):
        await run_import(sessionmaker, EsklpImporter(enabled=False), tmp_path)

    found = await rows(engine, "SELECT count(*) FROM catalog.import_runs")
    assert found[0][0] == 0
