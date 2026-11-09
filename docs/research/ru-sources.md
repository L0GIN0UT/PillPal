# RU drug catalog sources — research (2026-10-21)

**Summary (EN).** Russia has no openly licensed bulk drug catalog with brand, INN, form, strength,
manufacturer and barcode in one file except **ЕСКЛП** (the state catalog behind public procurement,
`esklp.egisz.rosminzdrav.ru`, XML/xlsx per the official passport schema: СМНН = INN + form + strength,
КЛП = trade item with `trade_name`, packs, `owner`, `manufacturer`, `barcode`), which is published for
download but has **no license text** anywhere; 1С and Vidal use it on undisclosed terms. **ГРЛС**
(`grls.rosminzdrav.ru`) has the same data as HTML cards plus a search-result Excel export, no bulk dump or
API, and the Minzdrav site terms (2014) forbid commercial use; the Minzdrav/data.gov.ru open-data CSV of
ГРЛС is from 2017. **Росздравнадзор opendata** has an explicit open license (free, commercial use allowed,
attribution required) but holds no catalog, only licenses, quality-control and recalled-series data.
**Честный знак / Национальный каталог**, **Vidal** and **РЛС** are contract-only (no public GTIN lookup;
scraping forbidden). **Wikidata** is CC0 but covers INN/ATC only, with almost no Russian brands.
Recommendation (owner decision D1, refined 2026-10-22): milestone 4.4b = ЕСКЛП importer (xlsx/XML, КЛП + СМНН,
barcode field) behind `CATALOG_IMPORTER_ESKLP_ENABLED` + Росздравнадзор opendata importer for recalled-series
flags; ГРЛС only as a documented manual monthly Excel export path (no scraping); Wikidata as optional INN
enrichment; Честный знак/НК/Vidal/РЛС rejected. Owner actions: verify that the ЕСКЛП file downloads without
authentication, send a written request to Minzdrav/ЦНИИОИЗ on the terms of use, and take lawyer questions 1–7
below into the Phase 4 legal review. The Russian text below is the research as written; links marked
«не проверено» could not be opened from the sandbox and were described from secondary sources.

---

# Открытые источники справочника лекарств РФ для PillPal (Phase 4) — исследование 2026-10-21

Контекст: нужен каталог «ТН + МНН + форма + дозировка + производитель (+ GTIN/EAN)» для RU без (пока не подтверждённой)
коммерческой лицензии ЕСКЛП. Ограничения исследования: grls.rosminzdrav.ru, esklp.egisz.rosminzdrav.ru, nsi.rosminzdrav.ru,
docs.crpt.ru, data.gov.ru, apicrafter недоступны из песочницы (robots/прокси) — их страницы описаны по вторичным источникам и
помечены «не проверено». Юридическая квалификация ниже — ориентир для вопросов юристу, не заключение.

## Общая правовая рамка (применима к п.1–4)
- Ст. 1259(6) ГК РФ: официальные документы госорганов и их переводы — не объекты авторского права; сами реестры ГРЛС/ГРПОЦ
  — официальная информация. Но право изготовителя базы данных (ст. 1334 ГК) и условия сайта — отдельный вопрос для юриста.
- «Типовые условия использования общедоступной информации в форме открытых данных» (протокол Правкомиссии по открытому
  правительству № 6 от 19.09.2016): пользователь «вправе свободно осуществлять поиск, получение, передачу и распространение
  открытых данных», «не ограничен в их использовании в некоммерческих и коммерческих целях», «не требуется заключать
  договор»; обязан «указывать ссылку на источник», использовать «только в законных целях», представлять «в достоверном виде»
  ([legalacts](https://legalacts.ru/doc/tipovye-uslovija-ispolzovanija-obshchedostupnoi-informatsii-razmeshchaemoi-v/),
  [pravo.ppt.ru](https://pravo.ppt.ru/usloviya/13248)). Действуют только для наборов, опубликованных «в форме открытых данных».

## 1. ГРЛС (grls.rosminzdrav.ru)
- Поля карточки: № РУ, даты, держатель РУ, ТН, МНН/группировочное, лек. формы+дозировки, стадии производства/производители,
  **штрих-коды потребительских упаковок (EAN-13)**, НД, ФТГ, цены ЖНВЛП ([zdravmedinform](https://zdravmedinform.ru/grls.html)).
  ~35 тыс. РУ ([vaskov.pro](https://vaskov.pro/grls)). Формат: HTML-карточки, Excel-экспорт результатов поиска и выгрузка цен
  ЖНВЛП в xls (так работает 1С-обработка на [infostart](https://infostart.ru/1c/tools/577639/)). Официального bulk-дампа и API нет.
  Обновление — непрерывное (ежедневно).
- Открытые данные Минздрава: набор `7707778246-grls` в CSV, «Ежеквартально», но последняя версия **2017-03-01**, 7 снимков
  2016–2017, лицензия в meta.csv не указана ([minzdrav opendata](https://minzdrav.gov.ru/opendata/list),
  [grls/meta.csv](https://minzdrav.gov.ru/opendata/7707778246-grls/meta.csv)). Структура CSV без штрих-кодов (не проверено).
- Условия сайта Минздрава (2014): копирование «допускается при условии указания ссылки на источник», но информация «не может
  рассматриваться как объект для использования в коммерческих целях»
  ([minzdrav.gov.ru/ministry/web-site/info](https://minzdrav.gov.ru/ministry/web-site/info)). У самого grls.rosminzdrav.ru
  отдельных условий/robots-запрета не найдено (не проверено). Сайт регулярно парсят (fl.ru, GitHub, vaskov.pro, brandquad).
- Вердикт: **неясно/серая зона** — данные по закону открыты (ФЗ-61 ст. 33: реестр публикуется), но bulk-скрейпинг прямо не
  разрешён, условия сайта Минздрава формально запрещают коммерческое использование. Открытый CSV устарел на 9 лет.
- Подводные камни: антибот-защита и смена вёрстки; штрих-коды в карточках заполнены не у всех РУ; дозировки — свободный текст.

## 2. ЕСКЛП (esklp.egisz.rosminzdrav.ru)
- Что есть: уровни СМНН (МНН+форма+дозировка, ATX, ЖНВЛП/наркотич. флаги) и КЛП (товарная позиция): `trade_name`, `pack_1/pack_2`
  (первичная/потребительская упаковка, кол-во), `owner`, `num_reg`, `date_reg`, **`barcode` (8–14 цифр, т.е. EAN/GTIN)**,
  `manufacturer` (name, country, address), предельные цены ЖНВЛП, UUID+hash версии — схема XML в Паспорте ЕСКЛП (Минздрав,
  27.11.2017, прил. Д/Е, [garant](https://base.garant.ru/71920072/7dede6ac8f25be619ed07c17ed1c62c9/)). Это ровно наш каталог.
- Доступ: портал «открытый онлайн-каталог» (пресс-релиз Минздрава/Ростех 2019:
  [minzdrav](https://minzdrav.gov.ru/news/2019/12/24/13072-minzdrav-i-rosteh-zapustili-onlayn-katalog-zaregistrirovannyh-v-rf-lekarstvennyh-preparatov)),
  на портале есть «Скачать ЕСКЛП одним файлом» (xlsx) и раздел «Документы» с актуальной версией
  ([Pirogov-vestnik 2020](https://www.pirogov-vestnik.ru/upload/iblock/604/2020_3_2_17.pdf),
  [ppt.ru 2024](https://ppt.ru/art/zakupki/gde-nayti-i-kak-rabotat-so-spravochnikom-yesklp-poshagovaya-instruktsiya)).
  Письмо Минздрава 09.11.2018 № 18-2/2055 «о предоставлении доступа к ЕСКЛП» указывает FTP ftp.esklp.rosminzdrav.ru и
  portal.egisz.rosminzdrav.ru ([garant](https://base.garant.ru/402999282/), текст нечитаем из песочницы). Также ЕСКЛП раздаётся
  как справочники ФРНСИ (nsi.rosminzdrav.ru, OID 1.2.643.5.1.13.13.99.2.611 «Узлы СМНН», …540 «ЕСКЛП с кодами КТРУ»), XML/ZIP по
  userKey; зеркала у apicrafter ([nsimz-4721](https://data.apicrafter.ru/packages/nsimz-4721), [esklpnumreg](https://data.apicrafter.ru/packages/esklpnumreg)).
- Обновление: автоматически при изменении ГРЛС/ГРПОЦ; референтные цены 1 мая и 1 ноября.
- Лицензия: **нигде не найдено ни текста условий, ни тарифов, ни «коммерческой лицензии»**. Владелец — Минздрав; оператор
  ЕГИСЗ. 1С и Видаль используют ЕСКЛП в продуктах ([1С](https://v8.1c.ru/its/docs/spravochnik-lekarstvennykh-preparatov/),
  [Vidal](https://www.vidal.ru/services/bd-vidal)) — на каких основаниях, публично не сказано. Вердикт: **неясно, скорее
  «разрешено с указанием источника» если файл лежит в открытом доступе**; подтвердить письменным запросом в Минздрав/ЦНИИОИЗ.
- Камни: заточен под госзакупки (140 тыс. позиций в 2019, покрытие ГРЛС полное); `barcode` может быть пустым.

## 3. data.gov.ru и открытые данные Минздрава
- data.gov.ru перезапущен 15.07.2025 (~4.7 тыс. наборов, ~84% 2019 г. и старше; есть API)
  ([tochno.st](https://tochno.st/materials/portal-otkrytyx-dannyx-vozobnovil-rabotu-posle-dvuxletnego-pereryva-80-datasetov-byli-vylozeny-do-2024-goda-i-s-tex-por-ne-obnovlialis),
  [Begtin](https://begtin.substack.com/p/datagovru)); недоступен из песочницы, наборы по лекарствам не проверены — ожидаемо те же CSV Минздрава.
- Минздрав: `7707778246-grls` (2017), `…gosreestrpredelnyhotpusknyhcen` (цены ЖНВЛП, 2017-02-10, «valid until 2017-04-30»),
  перечни ЖНВЛП 2016/2017 — все CSV, мёртвые. Лицензия не указана; применимы Типовые условия 2016 (коммерческое использование
  разрешено, ссылка на источник обязательна). Вердикт: **разрешено с атрибуцией, но бесполезно по свежести**.

## 4. Росздравнадзор (roszdravnadzor.gov.ru/opendata)
- Условия прямо: «Пользователь может использовать (в том числе повторно) открытые данные свободно, бесплатно, бессрочно,
  безвозмездно», «использовать открытые данные в коммерческих целях», обязан «сохранять ссылку на источник», «не искажать»
  ([roszdravnadzor opendata](https://roszdravnadzor.gov.ru/opendata)). Вердикт: **разрешено с атрибуцией**.
- Но наборы — не каталог: реестр лицензий фармдеятельности (XML 15 МБ), госконтроль качества ЛС (CSV 11 МБ), отсутствие ЖНВЛП
  в регионах, динамика цен; «изъятие из обращения» — только через ЕСИА. Полезно для флага «серия отозвана», не для каталога.

## 5. Честный знак / ЦРПТ / Национальный каталог / GS1
- Публичного GTIN→карточка нет: «Публичной страницы, куда вставляешь GTIN и получаешь карточку Национального каталога, не
  существует» ([selsup](https://selsup.ru/blog/kak-proverit-gtin/)). API НК — по apikey участника оборота (УКЭП, ГИС МТ),
  лимиты 429 на метод ([selsup API](https://selsup.ru/blog/rabota-s-api-v-chestnogo-znake/); docs.crpt.ru недоступен из песочницы).
  Мобильный API «Честного ЗНАКа» не документирован для третьих лиц. Лекарства в МДЛП описываются данными Минздрава (ЕСКЛП-id,
  РУ, ТН, МНН, упаковки — ПП № 1556; [markirovka.ru](https://markirovka.ru/knowledge/lekarstva/poleznaya-info-mdlp/svedeniya-peredavaemye-iz-minzdrava-v-sistemu-markirovki-chestnyy-znak-dlya-lekarstvennykh-preparatov)).
  Вердикт: **нужен статус участника/договор; для B2C — forbidden де-факто**.
- GS1 Россия: «Верифицировано ГС1» (search.gs1ru.org) — бесплатный поиск по GTIN без членства, возвращает только владельца
  префикса/название/страну, без карточки. Членство 25 000 ₽ вступительный + 15 000 ₽/год
  ([gs1ru](https://www.gs1ru.org/join/membership/)); условий на реиспользование реестра нет. Вердикт: **unclear, для каталога бесполезно**.

## 6. Vidal / РЛС
- Vidal «База данных для разработчиков»: MS Access/API (открытый формат) или MS SQL+DLL, все ЛС РФ, фото упаковок,
  соответствие кодам ЕСКЛП, ATX/МКБ-10; цены — по запросу ([vidal.ru](https://www.vidal.ru/services/bd-vidal)). GTIN не упомянут.
- РЛС: Web API для разработчиков с ТН, МНН, формами, **EAN-поиском**, маппингом на СМНН/КЛП, взаимодействиями
  ([rls-aurora.ru/Help](https://rls-aurora.ru/Help)); сайт: «Запрещена передача, копирование, распространение информации без
  разрешения администратора сайта, а также коммерческое использование материалов» ([rlsnet.ru](https://www.rlsnet.ru/)).
- Вердикт: **только по договору (needs contract)**; цены не публикуются; скрейпинг — forbidden.

## 7. Wikidata / Википедия
- Wikidata (CC0): элементы «medication» в основном по МНН/веществам; свойства для № РУ ГРЛС нет; российские ТН — единицы
  (элемент «list of Russian drugs» Q130564660; en-wiki список ~88 препаратов, без форм/дозировок/производителей
  ([List of Russian drugs](https://en.wikipedia.org/wiki/List_of_Russian_drugs))). Вердикт: **allowed (CC0/CC BY-SA), но
  покрытие бренд-уровня ≈0**; годится только для МНН↔ATC↔описаний на RU/EN.

## 8. Прочее
- Единый реестр ЛС ЕАЭС ([EEC](https://eec.eaeunion.org/comission/department/deptexreg/formirovanie-obshchikh-rynkov/drug-registry-eaeu.php)) — РУ по правилам Союза; лицензия не проверена.

## Рекомендация: стек для Phase 4 (по убыванию приоритета)
1. **ЕСКЛП xlsx/XML (КЛП + СМНН)** — первичный импорт: ТН, МНН, форма, дозировка, упаковки, производитель, `barcode`, РУ.
   Перед импортом: (а) скачать файл руками с esklp.egisz.rosminzdrav.ru/documents или FTP и зафиксировать, что он лежит в
   открытом доступе без авторизации; (б) направить письменный запрос в Минздрав (Деп. цифрового развития) / ЦНИИОИЗ об
   условиях использования в коммерческом приложении. Хранить `klp.UUID`/`smnn.UUID` как внешние ключи, версию файла и дату.
2. **ГРЛС** — только как инкрементальный источник (новые РУ, статус РУ, EAN-коды, которых нет в КЛП), через ручной Excel-экспорт
   раз в месяц, не скрейпинг карточек; хранить ссылку на источник.
3. **Росздравнадзор opendata** — флаги «серия изъята/брак» (CSV, лицензия явная). Отдельная таблица, без медицинских логов.
4. **Пользовательский вклад**: ручной ввод названия/дозы остаётся основным UX-путём (TZ не требует каталога для напоминаний);
   сканирование EAN → поиск по `barcode` в локальном каталоге → fallback «добавить вручную», с модерацией и без отправки
   пользовательских строк в аналитику. GTIN-14 DataMatrix (01…) → GTIN-13 отбрасыванием ведущего нуля.
5. **Wikidata** — обогащение МНН (EN/RU-синонимы, ATC) для EU-региона и поиска по латинице.
6. Vidal/РЛС — только если нужны инструкции/взаимодействия (платно, договор). Честный знак/НК — не использовать в B2C.

## Вопросы юристу
1. Являются ли ГРЛС и ЕСКЛП «официальными документами» по ст. 1259(6) ГК РФ, и исключает ли это смежное право изготовителя
   базы данных (ст. 1334 ГК) у Минздрава/ЦНИИОИЗ/Ростеха?
2. Распространяются ли «Типовые условия использования открытых данных» (2016) на файл ЕСКЛП с esklp.egisz.rosminzdrav.ru и на
   выгрузки ГРЛС, которые не опубликованы «в форме открытых данных» на opendata-странице?
3. Условия сайта Минздрава («не может рассматриваться как объект для использования в коммерческих целях», 2014) — применимы ли
   к grls.rosminzdrav.ru/esklp.egisz.rosminzdrav.ru (другие домены) и к коммерческому приложению с бесплатным каталогом?
4. Правомерен ли автоматизированный сбор (Excel-экспорт/парсинг) ГРЛС без явного запрета в условиях сайта; риски по ст. 272 УК /
   ст. 13.11 КоАП отсутствуют?
5. Как оформить запрос в Минздрав на использование ЕСКЛП коммерческой организацией; нужен ли договор с ЦНИИОИЗ как оператором
   ЕГИСЗ; есть ли «коммерческая лицензия ЕСКЛП» де-юре?
6. Атрибуция источника в приложении (где/как указывать Минздрав/Росздравнадзор) и дисклеймер об ошибках реестра в ПС.
7. Пользовательские EAN/названия в общем модерируемом каталоге: ПДн или нет, согласие, допустим ли перенос каталога RU↔EU.

## Сводная таблица
| # | Источник | Поля | Формат | Обновление | Лицензия (коммерч.) | Главный риск |
|---|---|---|---|---|---|---|
| 1 | ГРЛС сайт | ТН, МНН, форма/доза, производители, EAN, РУ, цены ЖНВЛП | HTML, Excel-экспорт поиска, xls цен | ежедневно | unclear (условия сайта Минздрава против коммерч.) | скрейпинг, антибот, свободный текст |
| 1b | Минздрав opendata grls | как ГРЛС (CSV), без EAN? | CSV | заявлено квартально, факт 2017 | allowed+attribution (Типовые условия) | мертвые данные |
| 2 | ЕСКЛП (портал/FTP/НСИ) | СМНН+КЛП: ТН, МНН, форма, доза, упаковки, производитель, **barcode**, РУ, цены | xlsx, XML/ZIP | при изменении ГРЛС | unclear → likely allowed+attribution; подтвердить письмом | нет текста условий |
| 3 | data.gov.ru | дубли Минздрава | CSV/API | 2017 | allowed+attribution | устарело |
| 4 | Росздравнадзор opendata | лицензии, брак/изъятие, цены ЖНВЛП | CSV/XML | нерегулярно | allowed+attribution (явно) | нет каталога |
| 5a | Честный знак / НК API | карточки GTIN, МДЛП | REST, apikey/УКЭП | онлайн | needs contract/participant | недоступно B2C |
| 5b | GS1 search.gs1ru.org | владелец GTIN | web | онлайн | unclear | нет карточки |
| 6 | Vidal / РЛС | полный, EAN, ЕСКЛП-коды, инструкции | Access/SQL/API | непрерывно | needs contract; сайт — forbidden | цена не публична |
| 7 | Wikidata/Wikipedia | МНН, ATC, описания | SPARQL/dumps | непрерывно | allowed (CC0/CC BY-SA) | нет RU-брендов |
| 8 | Реестр ЛС ЕАЭС | РУ ЕАЭС | web/xlsx | онлайн | unclear | не проверено |
