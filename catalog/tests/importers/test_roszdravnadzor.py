"""Roszdravnadzor recalled-series list: CSV parsing, fetch, and the join to ESKLP products."""

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
    reason_code_of,
)
from catalog.services.cards import product_card
from tests.importers import ru_data
from tests.importers.ru_data import RZN_DIR, uid
from tests.importers.support import dump, rows

Sessions = async_sessionmaker[AsyncSession]
NOW = datetime(2026, 11, 1, tzinfo=UTC)
URL = "https://roszdravnadzor.gov.ru/opendata/recalls/data.csv"


def _snapshot(tmp_path: Path, content: bytes | None = None, name: str = "snap") -> Path:
    folder = tmp_path / name
    folder.mkdir()
    data = content if content is not None else ru_data.rzn_csv().encode("utf-8")
    (folder / "recalls.csv").write_bytes(data)
    return folder


def _parse(folder: Path) -> tuple[list[RecallRecord], dict[str, int]]:
    importer = RoszdravnadzorImporter(enabled=True)
    records = [r for r in importer.parse(folder) if isinstance(r, RecallRecord)]
    return records, dict(importer.skipped)


def test_the_committed_fixture_is_the_generated_one() -> None:
    expected = ru_data.rzn_csv().encode("utf-8")
    assert (RZN_DIR / "recalls.csv").read_bytes() == expected


def test_rows_become_recall_records_with_normalized_numbers_and_codes(tmp_path: Path) -> None:
    records, skipped = _parse(_snapshot(tmp_path))

    assert [(r.registration_number, r.series, r.reason_code) for r in records] == [
        ("ЛП-000001", "А010124", "substandard"),
        ("ЛП-000001", "А020124", "counterfeit"),
        ("ЛП-000005", "Б5", "suspended"),
        ("ЛП-000002", "В7", "other"),
    ]
    assert records[0].published_at == datetime(2026, 9, 1, tzinfo=UTC)
    assert records[3].published_at is None
    assert skipped == {"invalid_row": 2}


@pytest.mark.parametrize(
    ("text", "code"),
    [
        ("Забракована: показатель", "substandard"),
        ("недоброкачественное", "substandard"),
        ("Фальсификат", "counterfeit"),
        ("Изъята из обращения", "withdrawn"),
        ("Приостановлено", "suspended"),
        ("что-то еще", "other"),
        ("", "other"),
    ],
)
def test_the_reason_text_is_reduced_to_a_code(text: str, code: str) -> None:
    assert reason_code_of(text) == code


def test_the_free_text_of_the_decision_is_not_kept(tmp_path: Path) -> None:
    records, _ = _parse(_snapshot(tmp_path))
    assert "растворение" not in repr(records)


def test_commas_tabs_cp1251_and_dotted_dates_are_read(tmp_path: Path) -> None:
    text = "Регистрационный номер,Серия,Решение,Дата решения\nЛП-000009,С1,Изъята,2026-08-02\n"
    records, _ = _parse(_snapshot(tmp_path, text.encode("cp1251")))
    assert [(r.registration_number, r.series, r.published_at) for r in records] == [
        ("ЛП-000009", "С1", datetime(2026, 8, 2, tzinfo=UTC))
    ]
    tabs = text.replace(",", "\t").encode("utf-8")
    assert _parse(_snapshot(tmp_path, tabs, "tabs"))[0] == records


def test_a_bad_date_keeps_the_row_without_a_date(tmp_path: Path) -> None:
    text = "Номер РУ;Серия;Причина;Дата\nЛП-000009;С1;Иное;31.02.2026\n"
    records, skipped = _parse(_snapshot(tmp_path, text.encode()))
    assert records[0].published_at is None
    assert skipped == {"invalid_date": 1}


def test_a_file_without_the_columns_or_rows_is_refused(tmp_path: Path) -> None:
    for name, content, code in [
        ("a", "Название;Цена\nx;1\n", "missing_columns"),
        ("b", "Номер РУ;Серия;Причина;Дата\n", "empty_snapshot"),
        ("c", "Номер РУ;Серия\n;\n", "empty_snapshot"),
        ("d", "", "missing_columns"),
    ]:
        with pytest.raises(ImporterDataError) as caught:
            _parse(_snapshot(tmp_path, content.encode(), name))
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
    lines = "".join(f"ЛП-{i:06d};С{i};Иное;\n" for i in range(20))
    folder = _snapshot(tmp_path, ("Номер РУ;Серия;Причина;Дата\n" + lines).encode())
    with pytest.raises(ImporterDataError) as caught:
        list(RoszdravnadzorImporter(enabled=True, max_rows=5).parse(folder))
    assert caught.value.code == "snapshot_too_large"


def test_a_cell_beyond_the_csv_field_limit_is_refused(tmp_path: Path) -> None:
    huge = "Номер РУ;Серия;Причина;Дата\nЛП-1;" + "x" * 200_000 + ";Иное;\n"
    with pytest.raises(ImporterDataError) as caught:
        _parse(_snapshot(tmp_path, huge.encode()))
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
    body = ru_data.rzn_csv().encode()
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
        "Номер РУ;Серия\n".encode(),
    ],
)
def test_a_download_that_is_not_a_usable_list_is_removed(tmp_path: Path, body: bytes) -> None:
    with pytest.raises((ImporterError, ArchiveRejected)):
        _importer(body).fetch(tmp_path / "out" / "snap")
    assert not (tmp_path / "out" / "snap").exists()


def test_a_pinned_checksum_must_match(tmp_path: Path) -> None:
    body = ru_data.rzn_csv().encode()
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

    assert result.counts["recall_flags"]["inserted"] == 4  # type: ignore[index]
    assert result.counts["parse_skipped"] == {"invalid_row": 2}
    async with sessionmaker() as session:
        card = await product_card(session, product_id("esklp", uid(101)))
        other = await product_card(session, product_id("esklp", uid(103)))
    assert card is not None
    assert other is not None
    assert [(r.series, r.reason_code, r.source) for r in card.recalls] == [
        ("А010124", "substandard", "ru_roszdravnadzor"),
        ("А020124", "counterfeit", "ru_roszdravnadzor"),
    ]
    assert other.recalls == []  # a registration number with no flag
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
    assert same.counts["recall_flags"]["unchanged"] == 4  # type: ignore[index]
    assert await dump(engine) == before

    text = "Номер РУ;Серия;Причина;Дата\nЛП-000001;А010124;Забракована;01.09.2026\n"
    await run_import(
        sessionmaker,
        RoszdravnadzorImporter(enabled=True),
        _snapshot(tmp_path, text.encode(), "short"),
    )
    assert (await rows(engine, "SELECT count(*) FROM catalog.recall_flags"))[0][0] == 4


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


async def test_a_name_in_the_decision_text_never_reaches_the_table(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    text = "Номер РУ;Серия;Причина;Дата\nЛП-000001;А1;Забракована ИП Выдуманов В.В.;01.09.2026\n"

    await run_import(
        sessionmaker, RoszdravnadzorImporter(enabled=True), _snapshot(tmp_path, text.encode())
    )

    found = await rows(engine, "SELECT t::text FROM catalog.recall_flags t")
    assert "Выдуманов" not in "".join(r[0] for r in found)
