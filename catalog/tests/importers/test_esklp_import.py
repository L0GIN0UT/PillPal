"""ESKLP end to end on real PostgreSQL: the fixture lands as Russian products, compositions,
packages and GTINs; a re-import withdraws what the snapshot no longer lists."""

from __future__ import annotations

from pathlib import Path

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.importers.base import ImporterDisabled
from catalog.importers.esklp import EsklpImporter
from catalog.importers.loader import run_import
from tests.importers import ru_data
from tests.importers.ru_data import uid
from tests.importers.support import DATA_TABLES, dump, rows

Sessions = async_sessionmaker[AsyncSession]


def _snapshot(tmp_path: Path, name: str = "snap", drop: str | None = None) -> Path:
    folder = tmp_path / name
    folder.mkdir()
    xml = ru_data.esklp_xml()
    if drop:
        xml = "".join(line for line in xml.splitlines(keepends=True) if drop not in line)
    (folder / "esklp.xml").write_text(xml, encoding="utf-8")
    return folder


async def test_a_refused_import_leaves_no_run_behind(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    with pytest.raises(ImporterDisabled):
        await run_import(sessionmaker, EsklpImporter(enabled=False), _snapshot(tmp_path))

    assert (
        await rows(engine, "SELECT count(*) FROM catalog.import_runs WHERE source <> 'consensus'")
    )[0][0] == 0
    assert (await rows(engine, "SELECT count(*) FROM catalog.products"))[0][0] == 0


async def test_the_fixture_loads_as_russian_products(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    result = await run_import(sessionmaker, EsklpImporter(enabled=True), _snapshot(tmp_path))

    counts = result.counts
    assert counts["products"]["inserted"] == 6  # type: ignore[index]
    assert counts["parse_skipped"]["invalid_klp"] == 1  # type: ignore[index]
    run = await rows(
        engine,
        "SELECT source, source_version, status FROM catalog.import_runs WHERE source <> 'consensus'",
    )
    assert [tuple(r) for r in run] == [("esklp", "2026-10-01", "succeeded")]

    products = await rows(
        engine,
        "SELECT brand_name, market, manufacturer, country, registration_number "
        "FROM catalog.products WHERE source = 'esklp' ORDER BY source_key",
    )
    assert tuple(products[0]) == ("Тестамол 500", "ru", 'ООО "Тест-Фарм"', "Россия", "ЛП-000001")
    assert {p[1] for p in products} == {"ru"}
    assert ru_data.IE_NAME not in {p[2] for p in products}  # a natural person: not stored

    forms = await rows(
        engine,
        "SELECT source_key, form_name_ru, complete FROM catalog.compositions ORDER BY source_key",
    )
    assert [(r[0], r[1], r[2]) for r in forms] == [
        (uid(1), "таблетки", True),
        (uid(2), "таблетки, покрытые пленочной оболочкой", True),
        (uid(3), "раствор для инъекций", False),
        (uid(5), "сироп", True),
    ]
    names = await rows(
        engine, "SELECT name FROM catalog.substance_names WHERE lang = 'ru' ORDER BY name"
    )
    assert {r[0] for r in names} == {"Пробинол", "Рамолин", "Тестамол", "Ёжикаин"}


async def test_gtins_come_from_the_barcode_and_only_when_shareable(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, EsklpImporter(enabled=True), _snapshot(tmp_path))

    gtins = await rows(
        engine,
        "SELECT g.gtin, p.source_key FROM catalog.gtins g "
        "JOIN catalog.packages p ON p.id = g.package_id WHERE g.source = 'esklp' ORDER BY g.gtin",
    )
    assert [tuple(g) for g in gtins] == [
        ("04600000000015", uid(101)),
        ("04600000000022", uid(105)),
        ("04600000000077", uid(105)),
    ]
    # the restricted and the badly summed numbers are not in the catalog at all
    assert await rows(engine, "SELECT count(*) FROM catalog.gtins WHERE gtin LIKE '0020%'") == [
        (0,)
    ]


async def test_search_entries_are_russian_and_fold_yo(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, EsklpImporter(enabled=True), _snapshot(tmp_path))

    found = await rows(
        engine,
        "SELECT e.entity_kind, e.lang, e.market FROM catalog.search_entries e "
        "WHERE e.norm = 'ежикаин' ORDER BY e.entity_kind",
    )
    assert [tuple(r) for r in found] == [("product", "ru", "ru"), ("substance", "ru", "ru")]


async def test_a_re_import_is_idempotent_and_withdraws_missing_rows(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    importer = EsklpImporter(enabled=True)
    await run_import(sessionmaker, importer, _snapshot(tmp_path))
    before = await dump(engine)

    again = await run_import(sessionmaker, importer, _snapshot(tmp_path, "again"))
    assert again.counts["products"]["unchanged"] == 6  # type: ignore[index]
    assert await dump(engine) == before

    smaller = _snapshot(tmp_path, "smaller", drop=uid(103))
    await run_import(sessionmaker, importer, smaller)
    gone = await rows(
        engine,
        "SELECT source_key FROM catalog.products WHERE withdrawn_at IS NOT NULL",
    )
    assert [r[0] for r in gone] == [uid(103)]
    assert (
        await rows(engine, "SELECT count(*) FROM catalog.packages WHERE withdrawn_at IS NOT NULL")
    )[0][0] == 1


async def test_the_source_row_is_enabled_after_the_first_successful_run(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    query = "SELECT enabled FROM catalog.sources WHERE code = 'esklp'"
    assert await rows(engine, query) == [(False,)]

    await run_import(sessionmaker, EsklpImporter(enabled=True), _snapshot(tmp_path))

    assert await rows(engine, query) == [(True,)]


async def test_no_personal_detail_of_an_individual_entrepreneur_is_stored(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, EsklpImporter(enabled=True), _snapshot(tmp_path))

    async with engine.connect() as conn:
        for table in DATA_TABLES:
            dumped = (await conn.execute(text(f"SELECT t::text FROM catalog.{table} t"))).all()  # noqa: S608
            assert ru_data.IE_ADDRESS not in "".join(r[0] for r in dumped), table
            assert "Тестоград" not in "".join(r[0] for r in dumped), table
            assert "Выдуманов" not in "".join(r[0] for r in dumped), table


async def test_an_xlsx_snapshot_loads_the_same_rows_as_the_xml(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    importer = EsklpImporter(enabled=True)
    await run_import(sessionmaker, importer, _snapshot(tmp_path))
    from_xml = await dump(engine, ("products", "packages", "gtins", "compositions"))
    ids = lambda dumped: {k: [r.split(",", 1)[0] for r in v] for k, v in dumped.items()}  # noqa: E731

    book = tmp_path / "book"
    book.mkdir()
    ru_data.esklp_xlsx(book / "esklp.xlsx")
    again = await run_import(sessionmaker, importer, book)

    assert again.counts["products"]["unchanged"] == 6  # type: ignore[index]
    assert ids(await dump(engine, ("products", "packages", "gtins", "compositions"))) == ids(
        from_xml
    )
