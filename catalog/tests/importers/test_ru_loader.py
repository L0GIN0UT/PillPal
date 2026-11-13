"""Loader support for the RU sources: recall flags, package links by registration number,
sources that never withdraw, shared substances, and the guard against a shrunken snapshot."""

from __future__ import annotations

from collections.abc import Iterator, Sequence
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.domain.gtin import check_digit
from catalog.importers.base import (
    CompositionRecord,
    ImporterError,
    IngredientRecord,
    LicenseNote,
    PackageLinkRecord,
    PackageRecord,
    ProductRecord,
    RecallRecord,
    Record,
    SnapshotManifest,
    SubstanceRecord,
)
from catalog.importers.loader import RECORD_BATCH_SIZE, run_import
from tests.importers.support import dump, rows

Sessions = async_sessionmaker[AsyncSession]
GTIN_A = "04600000000015"  # synthetic, valid check digit
GTIN_B = "14600000000012"
NOTE = LicenseNote(name="t", license="t", attribution="t", url="https://example.invalid/")


class ListImporter:
    """An importer over a fixed list of records (the loader is what is under test)."""

    license = NOTE

    def __init__(
        self,
        source: str,
        records: Sequence[Record],
        *,
        withdraws_missing: bool = True,
        enables_source: bool = False,
    ) -> None:
        self.source = source
        self._records = records
        self.withdraws_missing = withdraws_missing
        self.enables_source_on_success = enables_source

    def ensure_enabled(self) -> None:
        return None

    def fetch(self, dest: Path) -> SnapshotManifest:
        raise ImporterError("fetch_not_supported")

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        return None

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        yield from self._records


def _product(key: str, number: str | None, *gtins: str) -> ProductRecord:
    return ProductRecord(
        source_key=key,
        market="ru",
        brand_name=f"Тестамол {key}",
        registration_number=number,
        packages=(PackageRecord(source_key=key, gtins=gtins),),
    )


def _links(counts: dict[str, object]) -> tuple[object, ...]:
    return tuple(counts.get(f"package_links_{k}", 0) for k in ("matched", "ambiguous", "unmatched"))


async def _run(sessions: Sessions, importer: ListImporter, tmp_path: Path) -> dict[str, object]:
    return (await run_import(sessions, importer, tmp_path)).counts


async def test_recall_flags_are_upserted_and_never_removed(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    published = datetime(2026, 9, 1, tzinfo=UTC)
    first = [
        RecallRecord("ЛП-000001", "СЕРИЯ-1", "substandard", published),
        RecallRecord("ЛП-000001", "СЕРИЯ-2", "withdrawn", None),
    ]
    counts = await _run(sessionmaker, ListImporter("ru_roszdravnadzor", first), tmp_path)
    assert counts["recall_flags"] == {"inserted": 2, "updated": 0, "unchanged": 0, "withdrawn": 0}

    second = [RecallRecord("ЛП-000001", "СЕРИЯ-1", "counterfeit", published)]
    counts = await _run(sessionmaker, ListImporter("ru_roszdravnadzor", second), tmp_path)
    assert counts["recall_flags"]["updated"] == 1  # type: ignore[index]

    found = await rows(
        engine, "SELECT series, reason_code FROM catalog.recall_flags ORDER BY series"
    )
    assert [tuple(r) for r in found] == [("СЕРИЯ-1", "counterfeit"), ("СЕРИЯ-2", "withdrawn")]


async def test_an_unchanged_recall_list_changes_nothing(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    flags = [RecallRecord("ЛП-000001", "С1", "substandard", datetime(2026, 9, 1, tzinfo=UTC))]
    await _run(sessionmaker, ListImporter("ru_roszdravnadzor", flags), tmp_path)
    before = await dump(engine)

    counts = await _run(sessionmaker, ListImporter("ru_roszdravnadzor", flags), tmp_path)

    assert counts["recall_flags"]["unchanged"] == 1  # type: ignore[index]
    assert await dump(engine) == before


async def test_package_links_attach_a_gtin_to_the_unambiguous_esklp_package(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    products = [
        _product("k1", "ЛП-000001"),
        _product("k2", "ЛП-000002"),
        _product("k3", "ЛП-000002"),  # two packages share a number: ambiguous
    ]
    await _run(sessionmaker, ListImporter("esklp", products), tmp_path)
    links = [
        PackageLinkRecord("ЛП-000001", (GTIN_A,)),
        PackageLinkRecord("ЛП-000002", (GTIN_B,)),
        PackageLinkRecord("ЛП-999999", ("04600000000022",)),
    ]

    counts = await _run(sessionmaker, ListImporter("grls_manual", links), tmp_path)

    assert _links(counts) == (1, 1, 1)
    found = await rows(
        engine,
        "SELECT g.gtin, g.source, p.source, p.source_key FROM catalog.gtins g "
        "JOIN catalog.packages p ON p.id = g.package_id",
    )
    assert [tuple(r) for r in found] == [(GTIN_A, "grls_manual", "esklp", "k1")]
    assert await rows(
        engine, "SELECT count(*) FROM catalog.products WHERE source = 'grls_manual'"
    ) == [(0,)]


async def test_package_links_skip_withdrawn_esklp_rows(
    sessionmaker: Sessions, tmp_path: Path
) -> None:
    await _run(sessionmaker, ListImporter("esklp", [_product("k1", "ЛП-000001")]), tmp_path)
    await _run(sessionmaker, ListImporter("esklp", [_product("k9", "ЛП-000009")]), tmp_path)

    counts = await _run(
        sessionmaker,
        ListImporter("grls_manual", [PackageLinkRecord("ЛП-000001", (GTIN_A,))]),
        tmp_path,
    )

    assert _links(counts) == (0, 0, 1)


async def test_a_source_that_does_not_withdraw_keeps_its_gtins(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await _run(sessionmaker, ListImporter("esklp", [_product("k1", "ЛП-000001")]), tmp_path)
    grls = ListImporter(
        "grls_manual", [PackageLinkRecord("ЛП-000001", (GTIN_A,))], withdraws_missing=False
    )
    await _run(sessionmaker, grls, tmp_path)

    empty = ListImporter(
        "grls_manual", [PackageLinkRecord("ЛП-000001", ())], withdraws_missing=False
    )
    counts = await _run(sessionmaker, empty, tmp_path)

    live = await rows(engine, "SELECT count(*) FROM catalog.gtins WHERE withdrawn_at IS NULL")
    assert live == [(1,)]
    assert counts["gtins"]["withdrawn"] == 0  # type: ignore[index]


async def test_a_successful_run_enables_the_source_row(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    flag = "SELECT enabled FROM catalog.sources WHERE code = 'ru_roszdravnadzor'"
    assert await rows(engine, flag) == [(False,)]
    flags = [RecallRecord("ЛП-000001", "С1", "other", None)]

    with pytest.raises(ImporterError):
        await run_import(
            sessionmaker,
            ListImporter("ru_roszdravnadzor", [*flags, "x"], enables_source=True),
            tmp_path,  # type: ignore[list-item]
        )
    assert await rows(engine, flag) == [(False,)]

    await _run(
        sessionmaker, ListImporter("ru_roszdravnadzor", flags, enables_source=True), tmp_path
    )
    assert await rows(engine, flag) == [(True,)]


async def test_a_shared_substance_is_used_when_it_exists_else_the_local_one(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    rx = SubstanceRecord(source_key="5640", market="us", name_en="Ibuprofen")
    await _run(sessionmaker, ListImporter("rxnorm", [rx]), tmp_path)

    def composition(key: str, shared: tuple[str, str] | None) -> Sequence[Record]:
        local = SubstanceRecord(source_key=f"inn:{key}", market="ru", name_ru=f"Ибупрофен {key}")
        ingredient = IngredientRecord(
            substance_key=f"inn:{key}",
            strength_value=Decimal(200),
            strength_unit="мг",
            shared_substance=shared,
        )
        comp = CompositionRecord(
            source_key=key,
            market="ru",
            form_code="form:таблетки",
            form_name_ru="Таблетки",
            ingredients=(ingredient,),
            complete=True,
        )
        return [local, comp]

    records = [*composition("a", ("rxnorm", "5640")), *composition("b", ("rxnorm", "999"))]
    records = [r for r in records if isinstance(r, SubstanceRecord)] + [
        r for r in records if isinstance(r, CompositionRecord)
    ]
    await _run(sessionmaker, ListImporter("esklp", records), tmp_path)

    found = await rows(
        engine,
        "SELECT c.source_key, s.source, s.source_key FROM catalog.composition_ingredients i "
        "JOIN catalog.compositions c ON c.id = i.composition_id "
        "JOIN catalog.substances s ON s.id = i.substance_id WHERE c.source = 'esklp' "
        "ORDER BY c.source_key",
    )
    assert [tuple(r) for r in found] == [("a", "rxnorm", "5640"), ("b", "esklp", "inn:b")]


async def test_skipped_gtins_are_summed_over_batches(
    sessionmaker: Sessions, tmp_path: Path
) -> None:
    def wrong(i: int) -> str:
        body = f"{i + 1:013d}"
        return body + str((int(check_digit(body)) + 1) % 10)  # never the right check digit

    total = RECORD_BATCH_SIZE + 3
    products = [_product(f"k{i}", f"ЛП-{i:06d}", wrong(i)) for i in range(total)]

    counts = await _run(sessionmaker, ListImporter("esklp", products), tmp_path)

    assert counts["gtins_skipped"] == total


async def test_a_snapshot_that_lost_most_products_does_not_withdraw_them(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    full = [_product(f"k{i}", f"ЛП-{i:06d}") for i in range(120)]
    await _run(sessionmaker, ListImporter("esklp", full), tmp_path)
    before = await dump(engine)

    with pytest.raises(ImporterError) as caught:
        await run_import(sessionmaker, ListImporter("esklp", full[:20]), tmp_path)

    assert caught.value.code == "snapshot_shrunk"
    assert await dump(engine) == before
    failed = await rows(
        engine, "SELECT error_code FROM catalog.import_runs WHERE status = 'failed'"
    )
    assert failed == [("snapshot_shrunk",)]


async def test_a_small_catalog_may_shrink_and_no_withdraw_overrides_the_guard(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    full = [_product(f"k{i}", f"ЛП-{i:06d}") for i in range(120)]
    await _run(sessionmaker, ListImporter("esklp", full), tmp_path)

    result = await run_import(
        sessionmaker, ListImporter("esklp", full[:20]), tmp_path, withdraw_missing=False
    )

    assert result.counts["products"]["withdrawn"] == 0  # type: ignore[index]


def _gtin_of(i: int) -> str:
    body = f"46{i:010d}"
    return "0" + body + check_digit(body)


async def test_the_guard_looks_at_every_kind_not_only_products(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    with_gtins = [_product(f"k{i}", f"ЛП-{i:06d}", _gtin_of(i)) for i in range(120)]
    await _run(sessionmaker, ListImporter("esklp", with_gtins), tmp_path)
    before = await dump(engine)
    without = [_product(f"k{i}", f"ЛП-{i:06d}") for i in range(120)]  # every product, no GTIN

    with pytest.raises(ImporterError) as caught:
        await run_import(sessionmaker, ListImporter("esklp", without), tmp_path)

    assert caught.value.code == "snapshot_shrunk"
    assert await dump(engine) == before


async def test_normal_churn_passes_the_guard(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    first = [_product(f"k{i}", f"ЛП-{i:06d}", _gtin_of(i)) for i in range(120)]
    await _run(sessionmaker, ListImporter("esklp", first), tmp_path)
    second = [_product(f"k{i}", f"ЛП-{i:06d}", _gtin_of(i)) for i in range(10, 130)]

    result = await run_import(sessionmaker, ListImporter("esklp", second), tmp_path)

    assert result.counts["products"]["withdrawn"] == 10  # type: ignore[index]
    assert result.counts["gtins"]["withdrawn"] == 10  # type: ignore[index]


async def test_a_gtin_linked_to_two_packages_in_different_batches_is_dropped(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await _run(
        sessionmaker,
        ListImporter("esklp", [_product("k1", "ЛП-000001"), _product("k2", "ЛП-000002")]),
        tmp_path,
    )
    filler = [PackageLinkRecord(f"ЛП-9{i:05d}", ()) for i in range(RECORD_BATCH_SIZE - 1)]
    links = [
        PackageLinkRecord("ЛП-000001", (GTIN_A,)),
        *filler,
        PackageLinkRecord("ЛП-000002", (GTIN_A,)),
    ]

    counts = await _run(sessionmaker, ListImporter("grls_manual", links), tmp_path)

    assert (await rows(engine, "SELECT count(*) FROM catalog.gtins"))[0][0] == 0
    assert counts["gtins_skipped"] == 1


async def test_the_newest_decision_of_a_series_wins_within_a_file(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    newest_first = [  # the published file is sorted by letter date, newest first
        RecallRecord("ЛП-000001", "С1", "withdrawn", datetime(2026, 10, 1, tzinfo=UTC)),
        RecallRecord("ЛП-000001", "С1", "suspended", datetime(2026, 9, 1, tzinfo=UTC)),
        RecallRecord("ЛП-000001", "С1", "substandard", None),  # undated: the oldest
        RecallRecord("ЛП-000001", "С2", "suspended", datetime(2026, 9, 1, tzinfo=UTC)),
        RecallRecord("ЛП-000001", "С2", "substandard", datetime(2026, 9, 1, tzinfo=UTC)),
        RecallRecord("ЛП-000001", "С2", "suspended", datetime(2026, 9, 1, tzinfo=UTC)),
    ]
    await _run(sessionmaker, ListImporter("ru_roszdravnadzor", newest_first), tmp_path)

    found = await rows(
        engine, "SELECT series, reason_code FROM catalog.recall_flags ORDER BY series"
    )
    # on the same date a final decision ranks above a suspension
    assert [tuple(r) for r in found] == [("С1", "withdrawn"), ("С2", "substandard")]


async def test_an_older_decision_in_a_later_run_does_not_overwrite_a_newer_flag(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    october, september = datetime(2026, 10, 1, tzinfo=UTC), datetime(2026, 9, 1, tzinfo=UTC)
    first = [
        RecallRecord("ЛП-000001", "С1", "withdrawn", october),
        RecallRecord("ЛП-000001", "С2", "substandard", september),
        RecallRecord("ЛП-000001", "С3", "substandard", september),
    ]
    await _run(sessionmaker, ListImporter("ru_roszdravnadzor", first), tmp_path)
    second = [
        RecallRecord("ЛП-000001", "С1", "suspended", september),  # older: ignored
        RecallRecord("ЛП-000001", "С2", "suspended", september),  # same date, weaker: ignored
        RecallRecord("ЛП-000001", "С3", "counterfeit", october),  # newer: wins
        RecallRecord("ЛП-000001", "С1", "substandard", None),  # undated: ignored
    ]
    counts = await _run(sessionmaker, ListImporter("ru_roszdravnadzor", second), tmp_path)

    found = await rows(
        engine, "SELECT series, reason_code FROM catalog.recall_flags ORDER BY series"
    )
    assert [tuple(r) for r in found] == [
        ("С1", "withdrawn"),
        ("С2", "substandard"),
        ("С3", "counterfeit"),
    ]
    assert counts["recall_flags"]["updated"] == 1  # type: ignore[index]
