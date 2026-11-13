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
# The root ``date_create`` of the XML export (schema 21.5) is the snapshot version.
ESKLP_VERSION = "2026-10-01T00:00:00"
ESKLP_NS = "http://service.rosminzdrav.ru/ESKLP"

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
Pack = tuple[str, str]  # (num, name) as ESKLP prints pack_1 / pack_2
BLISTER: Pack = ("10", "блистер")
BOX: Pack = ("1", "пачка")
NO_PACK: Pack = ("", "")
# (uuid, smnn, trade name, manufacturer, country, num_reg, barcodes, pack_1, pack_2). Several
# barcodes are several ЖНВЛП price records of one КЛП (a repeated one is printed twice).
Klp = tuple[str, str, str, str, str, str, tuple[str, ...], Pack, Pack]
KLP: list[Klp] = [
    (
        uid(101),
        uid(1),
        "Тестамол 500",
        MAKER,
        "Россия",
        "ЛП-000001",
        ("4600000000015",),
        BLISTER,
        BOX,
    ),
    (
        uid(102),
        uid(2),
        "Тестамол Форте",
        IE_NAME,
        "Россия",
        "ЛП-000002",
        ("0200000000004",),
        BLISTER,
        BOX,
    ),
    (
        uid(103),
        uid(3),
        "Ёжикаин",
        MAKER,
        "Россия",
        "ЛП-000003",
        (),
        ("5", "ампула"),
        ("1", "коробка"),
    ),
    (
        uid(104),
        uid(4),
        "Тестамол 500 Дубль",
        MAKER,
        "Беларусь",
        " лп-000001 ",
        ("4600000000016",),
        BLISTER,
        BOX,
    ),
    (
        uid(105),
        uid(5),
        "Рамолин",
        MAKER,
        "Россия",
        "ЛП-000005",
        ("4600000000022", "4600000000077", "4600000000022"),
        ("100", "флакон"),
        ("1", "коробка"),
    ),
    (uid(106), uid(99), "Безымянный состав", MAKER, "Россия", "ЛП-000006", (), NO_PACK, NO_PACK),
]
# Rows an importer must drop and count: no trade name, a repeated КЛП key.
BAD_KLP: list[Klp] = [
    (uid(107), uid(1), "", MAKER, "Россия", "ЛП-000007", (), NO_PACK, NO_PACK),
    (uid(101), uid(1), "Тестамол 500 повтор", MAKER, "Россия", "ЛП-000001", (), NO_PACK, NO_PACK),
]
GOOD_KLP_COUNT = len(KLP)
# The group tree of the XML: (name, СМНН keys, nested groups). A nested group follows the
# СМНН list of its parent (schema 21.5), so the file order of the valid КЛП is the order of
# ``KLP``, the same as in the flat workbook.
Group = tuple[str, list[str], list["Group"]]
GROUPS: list[Group] = [
    ("Группа А", [uid(1), uid(2)], [("Группа Б", [uid(3), uid(4)], [])]),
    ("Группа В", [uid(5), uid(99)], []),  # uid(99): an СМНН without an INN
]

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


def pack_text(pack: Pack) -> str:
    """How a pack reads in a workbook cell and in the catalog: ``блистер (10)``."""
    num, name = pack
    return f"{name} ({num})" if name and num else name


def _cells(k: Klp) -> list[str | None]:
    """The trade-item columns of the two-sheet workbook."""
    barcodes = "; ".join(k[6])
    return [k[0], k[1], k[2], k[3], k[4], k[5], barcodes, pack_text(k[7]), pack_text(k[8])]


def _smnn_of(uuid: str) -> tuple[str, str, str]:
    found = next((s for s in SMNN if s[0] == uuid), None)
    return (found[1], found[2], found[3]) if found else ("", "", "")


def flat_rows(klp: list[Klp] | None = None) -> list[list[str | None]]:
    """One sheet: each КЛП row carries its СМНН columns."""
    rows: list[list[str | None]] = [list(KLP_HEADER)]
    for k in klp if klp is not None else KLP + BAD_KLP:
        inn, form, dosage = _smnn_of(k[1])
        cells = _cells(k)
        rows.append([*cells[:3], inn, form, dosage, *cells[3:5], IE_ADDRESS, *cells[5:]])
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
    klp_rows += [_cells(k) for k in KLP + BAD_KLP]
    smnn_rows: list[list[str | None]] = [["SMNN UUID", "МНН", "Лекарственная форма", "Дозировка"]]
    smnn_rows += [list(s) for s in SMNN]
    return build_xlsx(path, {"СМНН": smnn_rows, "КЛП": klp_rows})


def _e(tag: str, content: str) -> str:
    return f"<ns2:{tag}>{content}</ns2:{tag}>"


def _pack_xml(tag: str, pack: Pack) -> str:
    num, name = pack
    return _e(tag, _e("num", escape(num)) + _e("name", escape(name)))


def _dosage_xml(dosage: str) -> str:
    unit = _e("dosage_unit", _e("name", "мг") + _e("okei_code", "163") + _e("okei_name", "мг"))
    return _e("dosage", _e("grls_value", escape(dosage)) + unit)


def _barcodes_xml(k: Klp) -> str:
    """Schema 21.5 prints barcodes only in ЖНВЛП price records; the Belarusian КЛП prints its
    barcode as a direct child instead, to cover that layout too."""
    if k[4] == "Беларусь":
        return "".join(_e("barcode", b) for b in k[6])
    prices = "".join(
        _e("klp_lim_price", _e("price_value", "1.00") + _e("reg_num", "1") + _e("barcode", b))
        for b in k[6]
    )
    return _e("klp_lim_price_list", prices) if prices else ""


def _klp_xml(k: Klp) -> str:
    """One line per КЛП (tests drop a КЛП by its key). The owner block is never read."""
    uuid, _, name, maker, country, num_reg, _, pack_1, pack_2 = k
    owner = _e("owner", _e("name", escape(IE_NAME)) + _e("country_name", "Россия"))
    made_by = _e("name", escape(maker)) + _e("country_name", escape(country))
    return (
        f'      <ns2:klp hash="h" UUID={quoteattr(uuid)}>'
        + _e("code", "21.20.10")
        + _e("mnn_norm_name", "Нормализованное")
        + _e("trade_name", escape(name))
        + _pack_xml("pack_1", pack_1)
        + _pack_xml("pack_2", pack_2)
        + owner
        + _e("num_reg", escape(num_reg))
        + _e("manufacturer", made_by + _e("address", escape(IE_ADDRESS)))
        + _barcodes_xml(k)
        + "</ns2:klp>\n"
    )


def _smnn_xml(uuid: str) -> str:
    inn, form, dosage = _smnn_of(uuid)
    klp = [k for k in KLP + BAD_KLP if k[1] == uuid]
    return (
        f'    <ns2:smnn hash="h" UUID={quoteattr(uuid)}>'
        + _e("code", "21.20.10.000-000001")
        + _e("mnn", escape(inn))
        + _e("form", escape(form))
        + _dosage_xml(dosage)
        + "\n     <ns2:klp_list>\n"
        + "".join(_klp_xml(k) for k in klp)
        + "     </ns2:klp_list></ns2:smnn>\n"
    )


def _group_xml(group: Group, number: int) -> str:
    name, smnn, nested = group
    inner = "".join(_group_xml(g, number * 10 + i) for i, g in enumerate(nested, start=1))
    return (
        f"  <ns2:group name={quoteattr(name)} UUID={quoteattr(uid(900 + number))}>"
        + _e("date_change", "2026-09-30T00:00:00")
        + "\n   <ns2:smnn_list>\n"
        + "".join(_smnn_xml(u) for u in smnn)
        + "   </ns2:smnn_list>\n"
        + (f"  <ns2:group_list>\n{inner}  </ns2:group_list>\n" if nested else "")
        + "  </ns2:group>\n"
    )


def esklp_xml(groups: list[Group] | None = None) -> str:
    """The ESKLP XML export in the shape of schema 21.5 (``ESKLP > group_list > group >
    [group_list > group]* > smnn_list > smnn > klp_list > klp``), with synthetic values."""
    chosen = GROUPS if groups is None else groups
    body = "".join(_group_xml(g, i) for i, g in enumerate(chosen, start=1))
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<ns2:ESKLP xmlns:ns2="{ESKLP_NS}" UUID="{uid(0)}" date_create="{ESKLP_VERSION}" '
        'schemaVersion="21.5" contentType="fullActive">\n'
        f" <ns2:group_list>\n{body} </ns2:group_list>\n</ns2:ESKLP>\n"
    )


# Roszdravnadzor "drugs_qualitycontrol" open data, as the real file prints it: cp1251, ``;``,
# every field quoted, dd.mm.yyyy dates. It mixes negative decisions with permissions that must
# never become flags; "оригинальное ЛС" is a genuine product whose decision type still counts.
RZN_HEADER = [
    "trade_name",
    "no_ru",
    "dt_ru",
    "series",
    "producer",
    "country",
    "status",
    "type",
    "letter_number",
    "letter_date",
]


def rzn_row(no_ru: str, series: str, status: str, decision: str, date: str) -> list[str]:
    return [
        "Тестамол",
        no_ru,
        "24.11.2020",
        series,
        MAKER,
        "Россия",
        status,
        decision,
        "01И-1/26",
        date,
    ]


# rows that become flags: (registration number, series, reason code) in file order
RZN_ROWS = [
    rzn_row(
        "ЛП-000001", "А010124", "недоброкачественное ЛС", "Брак производителя Россия", "01.09.2026"
    ),
    rzn_row("ЛП-000001", "А020124", "фальсифицированное ЛС", "Изъятие", "15.09.2026"),
    # a genuine (not falsified) product recalled: the decision type says what happened
    rzn_row("ЛП-000001", "А030124", "оригинальное ЛС", "Отзыв", "15.09.2026"),
    rzn_row(
        "ЛП-000005", "Б7", "недоброкачественное ЛС", "Приостановление реализации", "30.09.2026"
    ),
    # suspended after an older permission: the suspension stands
    rzn_row("ЛП-000005", "Б8", "недоброкачественное ЛС", "Приостановление", "20.09.2026"),
    rzn_row(" лп-000002 ", "В7", "незаконный оборот", "_Изъятие", ""),
]
RZN_FLAGS = [
    ("ЛП-000001", "А010124", "substandard"),
    ("ЛП-000001", "А020124", "counterfeit"),
    ("ЛП-000001", "А030124", "withdrawn"),
    ("ЛП-000005", "Б7", "suspended"),
    ("ЛП-000005", "Б8", "suspended"),
    ("ЛП-000002", "В7", "withdrawn"),
]
# rows that must be skipped: permissions, a suspension lifted by a newer permission, a
# suspicion, a correction, missing keys
RZN_SKIPPED_ROWS = [
    rzn_row("ЛП-000003", "Д1", "оригинальное ЛС", "Разрешение реализации", "02.09.2026"),
    rzn_row(
        "ЛП-000005", "Б5", "недоброкачественное ЛС", "О разрешении к реализации серии", "05.10.2026"
    ),
    rzn_row(
        "ЛП-000005", "Б5", "недоброкачественное ЛС", "Приостановление реализации", "30.09.2026"
    ),
    rzn_row("ЛП-000005", "Б8", "недоброкачественное ЛС", "Разрешение (серия)", "01.09.2026"),
    rzn_row(
        "ЛП-000005", "Б6", "недоброкачественное ЛС", "О снятии с посерийного контроля", "05.10.2026"
    ),
    rzn_row("ЛП-000003", "Е2", "сомнительное ЛС", "Фальсификация приостановление", "03.09.2026"),
    rzn_row("ЛП-000006", "Ж3", "недоброкачественное ЛС", "Ошибка репортера", "04.09.2026"),
    rzn_row("ЛП-000006", "Ж4", "", "Отзыв", "04.09.2026"),
    rzn_row("", "Г1", "недоброкачественное ЛС", "Отзыв", "01.09.2026"),
    rzn_row("ЛП-000003", "", "недоброкачественное ЛС", "Отзыв", ""),
]
RZN_SKIPPED = {
    "decision_not_negative": 5,
    "suspension_lifted": 1,
    "status_suspected": 1,
    "status_unknown": 1,
    "invalid_row": 2,
}


def rzn_text(rows: list[list[str]] | None = None) -> str:
    def line(cells: list[str]) -> str:
        return ";".join('"' + c.replace('"', '""') + '"' for c in cells)

    chosen = RZN_ROWS + RZN_SKIPPED_ROWS if rows is None else rows
    return "\n".join([line(RZN_HEADER), *(line(r) for r in chosen)]) + "\n"


def rzn_csv(rows: list[list[str]] | None = None) -> bytes:
    """The file bytes (cp1251, like the published file)."""
    return rzn_text(rows).encode("cp1251")


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
