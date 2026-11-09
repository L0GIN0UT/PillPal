"""GRLS manual export: gated by its flag, no network, attaches barcodes to ESKLP packages only."""

from __future__ import annotations

import socket
from pathlib import Path

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.importers.base import (
    ImporterDataError,
    ImporterDisabled,
    ImporterError,
    PackageLinkRecord,
)
from catalog.importers.esklp import EsklpImporter
from catalog.importers.grls_manual import GrlsManualImporter
from catalog.importers.loader import run_import
from tests.importers import ru_data
from tests.importers.ru_data import uid
from tests.importers.support import dump, rows
from tests.importers.xlsx_support import build_xlsx

Sessions = async_sessionmaker[AsyncSession]


def _snapshot(tmp_path: Path, name: str = "grls") -> Path:
    folder = tmp_path / name
    folder.mkdir()
    ru_data.grls_xlsx(folder / "export.xlsx")
    return folder


def _importer() -> GrlsManualImporter:
    return GrlsManualImporter(enabled=True)


def test_every_operation_refuses_while_the_flag_is_off(tmp_path: Path) -> None:
    importer = GrlsManualImporter(enabled=False)
    snapshot = _snapshot(tmp_path)

    with pytest.raises(ImporterDisabled):
        importer.ensure_enabled()
    with pytest.raises(ImporterDisabled):
        importer.fetch(tmp_path / "out")
    with pytest.raises(ImporterDisabled):
        importer.snapshot_version(snapshot)
    with pytest.raises(ImporterDisabled):
        list(importer.parse(snapshot))


def test_there_is_no_fetch_and_no_network_is_touched(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def forbidden(*args: object, **kwargs: object) -> None:
        raise AssertionError("network access")

    monkeypatch.setattr(socket.socket, "connect", forbidden)
    monkeypatch.setattr(socket, "getaddrinfo", forbidden)

    with pytest.raises(ImporterError) as caught:
        _importer().fetch(tmp_path / "out")
    assert caught.value.code == "fetch_not_supported"
    assert not (tmp_path / "out").exists()
    assert list(_importer().parse(_snapshot(tmp_path)))


def test_rows_become_links_by_registration_number(tmp_path: Path) -> None:
    importer = _importer()

    records = list(importer.parse(_snapshot(tmp_path)))

    assert [r for r in records if isinstance(r, PackageLinkRecord)] == [
        PackageLinkRecord("ЛП-000002", ("04600000000039",)),
        PackageLinkRecord("ЛП-000001", ("04600000000046",)),
        PackageLinkRecord("ЛП-000003", ("04600000000053",)),
        PackageLinkRecord("ЛП-000999", ("04600000000060",)),
    ]
    assert dict(importer.skipped) == {"gtin_restricted": 1, "no_barcode": 1}
    assert importer.snapshot_version(_snapshot(tmp_path, "again")) == "2026-10-01"


def test_a_legacy_xls_is_refused_with_a_hint(tmp_path: Path) -> None:
    folder = tmp_path / "xls"
    folder.mkdir()
    (folder / "export.xls").write_bytes(b"\xd0\xcf\x11\xe0")

    with pytest.raises(ImporterError) as caught:
        list(_importer().parse(folder))
    assert caught.value.code == "unsupported_format"


def test_input_problems_are_refused(tmp_path: Path) -> None:
    nothing = tmp_path / "nothing"
    nothing.mkdir()
    two = _snapshot(tmp_path, "two")
    ru_data.grls_xlsx(two / "second.xlsx")
    cases: list[tuple[Path, str]] = [(nothing, "snapshot_not_found"), (two, "snapshot_ambiguous")]
    for path, code in cases:
        with pytest.raises(ImporterError) as caught:
            list(_importer().parse(path))
        assert caught.value.code == code

    wrong = tmp_path / "wrong"
    wrong.mkdir()
    build_xlsx(wrong / "e.xlsx", {"s": [["Название", "Цена"], ["Тестамол", "1"]]})
    empty = tmp_path / "empty"
    empty.mkdir()
    build_xlsx(empty / "e.xlsx", {"s": [ru_data.GRLS_HEADER]})
    for path, code in [(wrong, "missing_columns"), (empty, "empty_snapshot")]:
        with pytest.raises(ImporterDataError) as caught:
            list(_importer().parse(path))
        assert caught.value.code == code


def test_a_notes_sheet_before_the_data_sheet_is_skipped(tmp_path: Path) -> None:
    folder = tmp_path / "two-sheets"
    folder.mkdir()
    build_xlsx(
        folder / "e.xlsx",
        {"Справка": [["Экспорт ГРЛС"]], "Результаты": [ru_data.GRLS_HEADER, *ru_data.GRLS_ROWS]},
    )
    assert len(list(_importer().parse(folder))) == 4


async def _esklp(sessionmaker: Sessions, tmp_path: Path) -> None:
    folder = tmp_path / "esklp"
    folder.mkdir()
    (folder / "esklp.xml").write_text(ru_data.esklp_xml(), encoding="utf-8")
    await run_import(sessionmaker, EsklpImporter(enabled=True), folder)


async def test_barcodes_attach_to_unambiguous_esklp_packages_and_create_no_products(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await _esklp(sessionmaker, tmp_path)
    products_before = await dump(engine, ("products", "packages"))

    result = await run_import(sessionmaker, _importer(), _snapshot(tmp_path))

    assert await dump(engine, ("products", "packages")) == products_before
    assert result.counts["package_links_matched"] == 2
    assert result.counts["package_links_ambiguous"] == 1  # two trade items share the number
    assert result.counts["package_links_unmatched"] == 1
    attached = await rows(
        engine,
        "SELECT g.gtin, p.source_key FROM catalog.gtins g "
        "JOIN catalog.packages p ON p.id = g.package_id WHERE g.source = 'grls_manual' "
        "ORDER BY g.gtin",
    )
    assert [tuple(r) for r in attached] == [
        ("04600000000039", uid(102)),
        ("04600000000053", uid(103)),
    ]
    run = await rows(
        engine,
        "SELECT source_version, status FROM catalog.import_runs WHERE source = 'grls_manual'",
    )
    assert [tuple(r) for r in run] == [("2026-10-01", "succeeded")]
    flag = await rows(engine, "SELECT enabled FROM catalog.sources WHERE code = 'grls_manual'")
    assert flag == [(True,)]


async def test_a_later_partial_export_withdraws_nothing(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await _esklp(sessionmaker, tmp_path)
    await run_import(sessionmaker, _importer(), _snapshot(tmp_path))
    before = await dump(engine, ("gtins",))

    partial = tmp_path / "partial"
    partial.mkdir()
    build_xlsx(partial / "e.xlsx", {"s": [ru_data.GRLS_HEADER, ru_data.GRLS_ROWS[0]]})
    result = await run_import(sessionmaker, _importer(), partial)

    assert await dump(engine, ("gtins",)) == before
    assert result.counts["gtins"]["withdrawn"] == 0  # type: ignore[index]


async def test_a_run_before_esklp_attaches_nothing_and_is_not_an_error(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    result = await run_import(sessionmaker, _importer(), _snapshot(tmp_path))

    assert result.counts["package_links_unmatched"] == 4
    assert (await rows(engine, "SELECT count(*) FROM catalog.gtins"))[0][0] == 0


async def test_a_refused_run_leaves_no_trace(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    with pytest.raises(ImporterDisabled):
        await run_import(sessionmaker, GrlsManualImporter(enabled=False), _snapshot(tmp_path))
    assert (
        await rows(engine, "SELECT count(*) FROM catalog.import_runs WHERE source <> 'consensus'")
    )[0][0] == 0
