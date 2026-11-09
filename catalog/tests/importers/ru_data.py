"""Synthetic, format-faithful data of the Russian sources (privacy rule 9): invented names
("Тестамол"), invented registration numbers, barcodes with valid check digits, an invented
individual entrepreneur with an invented address. Nothing here is real. The ESKLP and
Roszdravnadzor fixtures under tests/fixtures/ are generated from it (a test keeps them equal)."""

from __future__ import annotations

from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

from tests.helpers import CATALOG_DIR
from tests.importers.xlsx_support import build_xlsx

FIXTURES = CATALOG_DIR / "tests" / "fixtures"
ESKLP_DIR = FIXTURES / "esklp"
RZN_DIR = FIXTURES / "roszdravnadzor"
ESKLP_VERSION = "2026-10-01"

# A person-like manufacturer (an individual entrepreneur) and the address printed next to it.
IE_NAME = "ИП Выдуманов Выдуман Выдуманович"
IE_ADDRESS = "г. Тестоград, ул. Выдуманная, д. 7"


def uid(number: int) -> str:
    return f"3f2c8a10-0000-4000-8000-{number:012d}"


# (uuid, inn, form, dosage)
SMNN = [
    (uid(1), "Тестамол", "таблетки", "500 мг"),
    (uid(2), "Тестамол + Пробинол", "таблетки, покрытые пленочной оболочкой", "250 мг+125 мг"),
    (uid(3), "Ёжикаин", "раствор для инъекций", ""),
    (uid(4), "Тестамол", "таблетки", "500 мг"),  # the same composition under another СМНН key
    (uid(5), "Рамолин", "сироп", "100 мг/5 мл"),
]
MAKER = 'ООО "Тест-Фарм"'
# (uuid, smnn, trade name, manufacturer, country, num_reg, barcode, pack_1, pack_2)
KLP = [
    (
        uid(101),
        uid(1),
        "Тестамол 500",
        MAKER,
        "Россия",
        "ЛП-000001",
        "4600000000015",
        "блистер",
        "пачка",
    ),
    (
        uid(102),
        uid(2),
        "Тестамол Форте",
        IE_NAME,
        "Россия",
        "ЛП-000002",
        "0200000000004",
        "блистер",
        "пачка",
    ),
    (uid(103), uid(3), "Ёжикаин", MAKER, "Россия", "ЛП-000003", "", "ампула", "коробка"),
    (
        uid(104),
        uid(4),
        "Тестамол 500 Дубль",
        MAKER,
        "Беларусь",
        " лп-000001 ",
        "4600000000016",
        "блистер",
        "пачка",
    ),
    (
        uid(105),
        uid(5),
        "Рамолин",
        MAKER,
        "Россия",
        "ЛП-000005",
        "4600000000022; 4600000000077",
        "флакон",
        "коробка",
    ),
    (uid(106), uid(99), "Безымянный состав", MAKER, "Россия", "ЛП-000006", "", "", ""),
]
# Rows an importer must drop and count: no trade name, a repeated КЛП key.
BAD_KLP = [
    (uid(107), uid(1), "", MAKER, "Россия", "ЛП-000007", "", "", ""),
    (uid(101), uid(1), "Тестамол 500 повтор", MAKER, "Россия", "ЛП-000001", "", "", ""),
]
GOOD_KLP_COUNT = len(KLP)

KLP_HEADER = [
    "KLP UUID",
    "SMNN UUID",
    "Торговое наименование",
    "МНН",
    "Лекарственная форма",
    "Дозировка",
    "Производитель",
    "Страна производителя",
    "Адрес производителя",
    "Номер РУ",
    "Штрихкод",
    "Первичная упаковка",
    "Потребительская упаковка",
]


def _smnn_of(uuid: str) -> tuple[str, str, str]:
    found = next((s for s in SMNN if s[0] == uuid), None)
    return (found[1], found[2], found[3]) if found else ("", "", "")


def flat_rows(klp: list[tuple[str, ...]] | None = None) -> list[list[str | None]]:
    """One sheet: each КЛП row carries its СМНН columns."""
    rows: list[list[str | None]] = [list(KLP_HEADER)]
    for k in klp if klp is not None else KLP + BAD_KLP:
        inn, form, dosage = _smnn_of(k[1])
        rows.append(
            [k[0], k[1], k[2], inn, form, dosage, k[3], k[4], IE_ADDRESS, k[5], k[6], k[7], k[8]]
        )
    return rows


def esklp_xlsx(path: Path, *, two_sheets: bool = False) -> Path:
    if not two_sheets:
        return build_xlsx(path, {"КЛП": flat_rows()})
    klp_rows: list[list[str | None]] = [
        [
            "KLP UUID",
            "SMNN UUID",
            "Торговое наименование",
            "Производитель",
            "Страна производителя",
            "Номер РУ",
            "Штрихкод",
            "Первичная упаковка",
            "Потребительская упаковка",
        ]
    ]
    klp_rows += [list(k) for k in KLP + BAD_KLP]
    smnn_rows: list[list[str | None]] = [["SMNN UUID", "МНН", "Лекарственная форма", "Дозировка"]]
    smnn_rows += [list(s) for s in SMNN]
    return build_xlsx(path, {"СМНН": smnn_rows, "КЛП": klp_rows})


def esklp_xml() -> str:
    parts = [f'<?xml version="1.0" encoding="UTF-8"?>\n<esklp version="{ESKLP_VERSION}">\n']
    for uuid, inn, form, dosage in SMNN:
        parts.append(
            f"  <smnn uuid={quoteattr(uuid)}><inn>{escape(inn)}</inn><form>{escape(form)}</form>"
            f"<dosage>{escape(dosage)}</dosage></smnn>\n"
        )
    for uuid, smnn, name, maker, country, num_reg, barcode, pack_1, pack_2 in KLP + BAD_KLP:
        parts.append(
            f"  <klp uuid={quoteattr(uuid)} smnn_uuid={quoteattr(smnn)}>"
            f"<trade_name>{escape(name)}</trade_name><pack_1>{escape(pack_1)}</pack_1>"
            f"<pack_2>{escape(pack_2)}</pack_2><num_reg>{escape(num_reg)}</num_reg>"
            f"<barcode>{escape(barcode)}</barcode><manufacturer><name>{escape(maker)}</name>"
            f"<country>{escape(country)}</country><address>{escape(IE_ADDRESS)}</address>"
            "</manufacturer></klp>\n"
        )
    parts.append("</esklp>\n")
    return "".join(parts)


# Roszdravnadzor: registration number, series, decision text, date (as the open-data CSV prints
# them: semicolon separated, UTF-8 with a BOM, dd.mm.yyyy dates).
RZN_HEADER = ["Номер РУ", "Серия", "Причина", "Дата"]
RZN_ROWS = [
    ["ЛП-000001", "А010124", "Забракована: несоответствие по показателю растворение", "01.09.2026"],
    ["ЛП-000001", "А020124", "Изъята из обращения: фальсифицированная", "15.09.2026"],
    ["ЛП-000005", "Б5", "Приостановлено применение", "30.09.2026"],
    [" лп-000002 ", "В7", "Иное", ""],
]
RZN_BAD_ROWS = [["", "Г1", "Забракована", "01.09.2026"], ["ЛП-000003", "", "Забракована", ""]]


def rzn_csv() -> str:
    lines = [";".join(RZN_HEADER)] + [";".join(r) for r in RZN_ROWS + RZN_BAD_ROWS]
    return "\ufeff" + "\n".join(lines) + "\n"


# GRLS manual export: registration number, trade name, barcode.
GRLS_HEADER = ["Номер РУ", "Торговое наименование", "Штрих-код"]
GRLS_ROWS = [
    ["ЛП-000002", "Тестамол Форте", "4600000000039"],
    ["ЛП-000001", "Тестамол 500", "4600000000046"],  # two КЛП share this number
    ["ЛП-000003", "Ёжикаин", "4600000000053 ; 0200000000004"],
    ["ЛП-000999", "Нет такого", "4600000000060"],
    ["ЛП-000005", "Рамолин", ""],
]


def grls_xlsx(path: Path) -> Path:
    return build_xlsx(path, {"Результаты поиска": [GRLS_HEADER, *GRLS_ROWS]})
