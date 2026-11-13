"""Roszdravnadzor quality-control list: CSV parsing, the negative-outcome allow-list, fetch, and
the join to ESKLP products."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.importers.archive import ArchiveRejected
from catalog.importers.base import ImporterDataError, ImporterError, RecallRecord
from catalog.importers.esklp import EsklpImporter
from catalog.importers.ids import product_id
from catalog.importers.loader import run_import
from catalog.importers.ru_roszdravnadzor import (
    MAX_CSV_BYTES,
    RoszdravnadzorImporter,
    outcome_of,
)
from catalog.services.cards import product_card
from tests.importers import ru_data
from tests.importers.ru_data import RZN_DIR, uid
from tests.importers.support import dump, rows

Sessions = async_sessionmaker[AsyncSession]
NOW = datetime(2026, 11, 1, tzinfo=UTC)
URL = "https://roszdravnadzor.gov.ru/opendata/7710537160-drugs_qualitycontrol/data-20261105.csv"
HEADER = ";".join(ru_data.RZN_HEADER)


def _snapshot(tmp_path: Path, content: bytes | None = None, name: str = "snap") -> Path:
    folder = tmp_path / name
    folder.mkdir()
    data = content if content is not None else ru_data.rzn_csv()
    (folder / "recalls.csv").write_bytes(data)
    return folder


def _row(no_ru: str = "ЛП-000009", series: str = "С1", date: str = "") -> list[str]:
    return ru_data.rzn_row(no_ru, series, "недоброкачественное ЛС", "Отзыв", date)


def _parse(folder: Path) -> tuple[list[RecallRecord], dict[str, int]]:
    importer = RoszdravnadzorImporter(enabled=True)
    records = [r for r in importer.parse(folder) if isinstance(r, RecallRecord)]
    return records, dict(importer.skipped)


def test_the_committed_fixture_is_the_generated_one() -> None:
    assert (RZN_DIR / "recalls.csv").read_bytes() == ru_data.rzn_csv()


def test_only_negative_outcomes_become_recall_records(tmp_path: Path) -> None:
    records, skipped = _parse(_snapshot(tmp_path))

    assert [(r.registration_number, r.series, r.reason_code) for r in records] == ru_data.RZN_FLAGS
    assert records[0].published_at == datetime(2026, 9, 1, tzinfo=UTC)  # letter_date
    assert records[-1].published_at is None  # В7 prints no date
    assert skipped == ru_data.RZN_SKIPPED


def test_a_permission_never_becomes_a_flag(tmp_path: Path) -> None:
    permissions = [
        ru_data.rzn_row("ЛП-000001", "А2", status, decision, "01.09.2026")
        for status in ("недоброкачественное ЛС", "фальсифицированное ЛС", "оригинальное ЛС")
        for decision in (
            "Разрешение реализации",
            "О разрешении к реализации серии",
            "О снятии с посерийного контроля",
            "О переводе на посерийный контроль",
            "Разрешение (серия)",
            "Изменение",
        )
    ]
    folder = _snapshot(tmp_path, ru_data.rzn_csv([*permissions, _row()]))

    records, skipped = _parse(folder)

    assert [(r.registration_number, r.series) for r in records] == [("ЛП-000009", "С1")]
    assert skipped == {"decision_not_negative": 18}


def test_a_recalled_genuine_product_is_flagged_by_its_decision(tmp_path: Path) -> None:
    # "оригинальное ЛС" means a genuine (not falsified) product; the type says what happened
    genuine = [
        ru_data.rzn_row("ЛП-000001", f"А{n}", "оригинальное ЛС", decision, "01.09.2026")
        for n, decision in enumerate(("Отзыв", "Прекращение обращения", "Приостановление"))
    ]
    records, _ = _parse(_snapshot(tmp_path, ru_data.rzn_csv(genuine)))

    assert [(r.series, r.reason_code) for r in records] == [
        ("А0", "withdrawn"),
        ("А1", "withdrawn"),
        ("А2", "suspended"),
    ]


def test_a_suspension_lifted_by_a_newer_permission_is_dropped(tmp_path: Path) -> None:
    def row(series: str, decision: str, date: str) -> list[str]:
        return ru_data.rzn_row("ЛП-000001", series, "недоброкачественное ЛС", decision, date)

    newest_first = [
        row("А1", "О разрешении к реализации серии", "05.10.2026"),  # lifts А1
        row("А2", "Приостановление реализации", "01.10.2026"),  # after А2's permission
        row("А1", "Приостановление реализации", "30.09.2026"),
        row("А2", "Разрешение (серия)", "01.09.2026"),
        row("А3", "Разрешение реализации", ""),  # undated: lifts nothing
        row("А3", "Приостановление", "01.08.2026"),
        row("А4", "Разрешение реализации", "05.10.2026"),  # lifts only suspensions
        row("А4", "Отзыв", "01.09.2026"),
    ]
    records, skipped = _parse(_snapshot(tmp_path, ru_data.rzn_csv(newest_first)))

    assert [(r.series, r.reason_code) for r in records] == [
        ("А2", "suspended"),
        ("А3", "suspended"),
        ("А4", "substandard"),
    ]
    assert skipped == {"decision_not_negative": 4, "suspension_lifted": 1}


@pytest.mark.parametrize(
    ("status", "decision", "outcome"),
    [
        ("недоброкачественное ЛС", "Брак производителя (территория)", ("substandard", None)),
        ("недоброкачественное ЛС", "Отзыв производителем (Ф/С)", ("substandard", None)),
        ("недоброкачественное ЛС", "Приостановление", ("suspended", None)),
        ("фальсифицированное ЛС", "Приостановление реализации", ("suspended", None)),
        ("фальсифицированное ЛС", "Отзыв", ("counterfeit", None)),
        ("незарегистрированное ЛС", "Изъятие", ("withdrawn", None)),
        ("  Незаконный   оборот ", " _ИЗЪЯТИЕ ", ("withdrawn", None)),
        ("недоброкачественное лс", "прекращение обращения", ("substandard", None)),
        ("оригинальное ЛС", "Отзыв", ("withdrawn", None)),
        ("оригинальное ЛС", "Изъятие", ("withdrawn", None)),
        ("оригинальное ЛС", "Приостановление реализации", ("suspended", None)),
        ("оригинальное ЛС", "Разрешение реализации", (None, "decision_not_negative")),
        ("сомнительное ЛС", "Фальсификация полное изъятие", (None, "status_suspected")),
        ("", "Отзыв", (None, "status_unknown")),
        ("новый статус", "Отзыв", (None, "status_unknown")),
        ("недоброкачественное ЛС", "", (None, "decision_not_negative")),
        ("недоброкачественное ЛС", "Новый вид решения", (None, "decision_not_negative")),
        ("недоброкачественное ЛС", "Ошибка репортера", (None, "decision_not_negative")),
    ],
)
def test_the_outcome_is_an_explicit_allow_list(
    status: str, decision: str, outcome: tuple[str | None, str | None]
) -> None:
    assert outcome_of(status, decision) == outcome


def test_the_free_text_of_the_decision_is_not_kept(tmp_path: Path) -> None:
    records, _ = _parse(_snapshot(tmp_path))
    text = repr(records)
    assert "Тестамол" not in text
    assert "01И-1/26" not in text
    assert ru_data.MAKER not in text


def test_utf8_commas_and_iso_dates_are_read(tmp_path: Path) -> None:
    text = ",".join(ru_data.RZN_HEADER) + "\n" + ",".join(_row(date="2026-08-02")) + "\n"
    records, _ = _parse(_snapshot(tmp_path, ("﻿" + text).encode("utf-8")))
    assert [(r.registration_number, r.series, r.published_at) for r in records] == [
        ("ЛП-000009", "С1", datetime(2026, 8, 2, tzinfo=UTC))
    ]
    tabs = text.replace(",", "\t").encode("utf-8")
    assert _parse(_snapshot(tmp_path, tabs, "tabs"))[0] == records


def test_a_bad_date_keeps_the_row_without_a_date(tmp_path: Path) -> None:
    records, skipped = _parse(_snapshot(tmp_path, ru_data.rzn_csv([_row(date="31.02.2026")])))
    assert records[0].published_at is None
    assert skipped == {"invalid_date": 1}


def test_a_file_without_the_columns_or_rows_is_refused(tmp_path: Path) -> None:
    old_shape = "Номер РУ;Серия;Причина;Дата\nЛП-1;С1;Забракована;\n"
    only_permissions = ru_data.rzn_csv(
        [ru_data.rzn_row("ЛП-1", "С1", "оригинальное ЛС", "Разрешение реализации", "")]
    )
    for name, content, code in [
        ("a", "Название;Цена\nx;1\n".encode(), "missing_columns"),
        ("b", old_shape.encode(), "missing_columns"),  # no status/type: nothing to decide on
        ("c", (HEADER + "\n").encode(), "empty_snapshot"),
        ("d", only_permissions, "empty_snapshot"),
        ("e", b"", "missing_columns"),
    ]:
        with pytest.raises(ImporterDataError) as caught:
            _parse(_snapshot(tmp_path, content, name))
        assert caught.value.code == code, name


def test_an_oversized_or_misplaced_input_is_refused(tmp_path: Path) -> None:
    folder = _snapshot(tmp_path)
    (folder / "second.csv").write_bytes(b"x")
    with pytest.raises(ImporterError) as caught:
        _parse(folder)
    assert caught.value.code == "snapshot_ambiguous"

    nothing = tmp_path / "nothing"
    nothing.mkdir()
    with pytest.raises(ImporterError) as caught:
        _parse(nothing)
    assert caught.value.code == "snapshot_not_found"

    big = _snapshot(tmp_path, b"x", "big")
    with pytest.raises(ImporterError) as caught:
        list(RoszdravnadzorImporter(enabled=True, max_csv_bytes=0).parse(big))
    assert caught.value.code == "snapshot_too_large"
    assert MAX_CSV_BYTES > 0


def test_the_row_limit_refuses_runaway_files(tmp_path: Path) -> None:
    folder = _snapshot(tmp_path, ru_data.rzn_csv([_row(series=f"С{i}") for i in range(20)]))
    with pytest.raises(ImporterDataError) as caught:
        list(RoszdravnadzorImporter(enabled=True, max_rows=5).parse(folder))
    assert caught.value.code == "snapshot_too_large"


def test_a_cell_beyond_the_csv_field_limit_is_refused(tmp_path: Path) -> None:
    huge = ru_data.rzn_csv([_row(series="x" * 200_000)])
    with pytest.raises(ImporterDataError) as caught:
        _parse(_snapshot(tmp_path, huge))
    assert caught.value.code == "invalid_snapshot"


def _importer(
    body: bytes, requested: list[str] | None = None, **options: object
) -> RoszdravnadzorImporter:
    def handler(request: httpx.Request) -> httpx.Response:
        if requested is not None:
            requested.append(str(request.url))
        return httpx.Response(200, content=body)

    return RoszdravnadzorImporter(
        enabled=True,
        transport=httpx.MockTransport(handler),
        now=lambda: NOW,
        url=URL,
        **options,  # type: ignore[arg-type]
    )


def test_fetch_stores_the_csv_and_reports_its_checksum(tmp_path: Path) -> None:
    body = ru_data.rzn_csv()
    requested: list[str] = []

    manifest = _importer(body, requested).fetch(tmp_path / "out")

    assert requested == [URL]
    assert (tmp_path / "out" / "recalls.csv").read_bytes() == body
    assert manifest.source == "ru_roszdravnadzor"
    assert len(manifest.sha256) == 64


@pytest.mark.parametrize(
    ("url", "code"),
    [
        (None, "url_required"),
        ("http://roszdravnadzor.gov.ru/a.csv", "fetch_insecure_url"),
        ("https://example.invalid/a.csv", "fetch_host_not_allowed"),
    ],
)
def test_the_url_is_the_operators_and_is_checked(
    tmp_path: Path, url: str | None, code: str
) -> None:
    requested: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested.append(str(request.url))
        return httpx.Response(200)

    importer = RoszdravnadzorImporter(enabled=True, transport=httpx.MockTransport(handler), url=url)
    with pytest.raises(ImporterError) as caught:
        importer.fetch(tmp_path / "out")
    assert caught.value.code == code
    assert requested == []
    assert not (tmp_path / "out").exists()


@pytest.mark.parametrize(
    "body",
    [
        b"<html><body>captcha</body></html>",
        b"",
        b"PK\x03\x04zip",
        (HEADER + "\n").encode(),
    ],
)
def test_a_download_that_is_not_a_usable_list_is_removed(tmp_path: Path, body: bytes) -> None:
    with pytest.raises((ImporterError, ArchiveRejected)):
        _importer(body).fetch(tmp_path / "out" / "snap")
    assert not (tmp_path / "out" / "snap").exists()


def test_a_pinned_checksum_must_match(tmp_path: Path) -> None:
    body = ru_data.rzn_csv()
    with pytest.raises(ImporterError) as caught:
        _importer(body, expected_sha256="0" * 64).fetch(tmp_path / "out")
    assert caught.value.code == "checksum_mismatch"
    assert not (tmp_path / "out").exists()


async def test_flags_join_esklp_products_by_registration_number(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    esklp = tmp_path / "esklp"
    esklp.mkdir()
    (esklp / "esklp.xml").write_text(ru_data.esklp_xml(), encoding="utf-8")
    await run_import(sessionmaker, EsklpImporter(enabled=True), esklp)

    result = await run_import(
        sessionmaker, RoszdravnadzorImporter(enabled=True), _snapshot(tmp_path)
    )

    assert result.counts["recall_flags"]["inserted"] == len(ru_data.RZN_FLAGS)  # type: ignore[index]
    assert result.counts["parse_skipped"] == ru_data.RZN_SKIPPED
    async with sessionmaker() as session:
        card = await product_card(session, product_id("esklp", uid(101)))
        other = await product_card(session, product_id("esklp", uid(103)))
    assert card is not None
    assert other is not None
    assert [(r.series, r.reason_code, r.source) for r in card.recalls] == [
        ("А010124", "substandard", "ru_roszdravnadzor"),
        ("А020124", "counterfeit", "ru_roszdravnadzor"),
        ("А030124", "withdrawn", "ru_roszdravnadzor"),
    ]
    assert other.recalls == []  # ЛП-000003: only a permission and a suspicion
    enabled = await rows(
        engine, "SELECT enabled FROM catalog.sources WHERE code = 'ru_roszdravnadzor'"
    )
    assert enabled == [(True,)]


async def test_a_second_run_changes_nothing_and_a_shorter_list_removes_nothing(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, RoszdravnadzorImporter(enabled=True), _snapshot(tmp_path))
    before = await dump(engine)

    same = await run_import(
        sessionmaker, RoszdravnadzorImporter(enabled=True), _snapshot(tmp_path, name="two")
    )
    assert same.counts["recall_flags"]["unchanged"] == len(ru_data.RZN_FLAGS)  # type: ignore[index]
    assert await dump(engine) == before

    await run_import(
        sessionmaker,
        RoszdravnadzorImporter(enabled=True),
        _snapshot(tmp_path, ru_data.rzn_csv(ru_data.RZN_ROWS[:1]), "short"),
    )
    flags = await rows(engine, "SELECT count(*) FROM catalog.recall_flags")
    assert flags[0][0] == len(ru_data.RZN_FLAGS)


def test_the_importer_needs_the_esklp_flag(tmp_path: Path) -> None:
    from catalog.importers.base import ImporterDisabled

    importer = RoszdravnadzorImporter()  # recall flags attach to ESKLP products: same gate
    for call in (
        lambda: importer.fetch(tmp_path / "o"),
        lambda: list(importer.parse(_snapshot(tmp_path))),
        lambda: importer.snapshot_version(tmp_path),
    ):
        with pytest.raises(ImporterDisabled):
            call()


def test_too_many_columns_are_refused(tmp_path: Path) -> None:
    wide = ";".join(f"c{i}" for i in range(300))
    with pytest.raises(ImporterDataError) as caught:
        _parse(_snapshot(tmp_path, (wide + "\n1;2\n").encode()))
    assert caught.value.code == "invalid_snapshot"


def test_a_symlinked_csv_is_ignored(tmp_path: Path) -> None:
    folder = tmp_path / "linked"
    folder.mkdir()
    target = _snapshot(tmp_path, name="real") / "recalls.csv"
    try:
        (folder / "link.csv").symlink_to(target)
    except OSError:
        pytest.skip("symlinks are not available")
    with pytest.raises(ImporterError) as caught:
        _parse(folder)
    assert caught.value.code == "snapshot_not_found"


def test_html_with_leading_whitespace_is_not_a_csv(tmp_path: Path) -> None:
    with pytest.raises(ImporterError) as caught:
        _importer(b"  \n <html>captcha</html>").fetch(tmp_path / "out")
    assert caught.value.code == "invalid_download"


async def test_a_name_in_the_row_never_reaches_the_table(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    row = _row()
    row[0], row[4] = "Тестамол ИП Выдуманов", "ИП Выдуманов В.В."  # trade name, producer
    content = ru_data.rzn_csv([row])

    await run_import(
        sessionmaker, RoszdravnadzorImporter(enabled=True), _snapshot(tmp_path, content)
    )

    found = await rows(engine, "SELECT t::text FROM catalog.recall_flags t")
    assert "Выдуманов" not in "".join(r[0] for r in found)
