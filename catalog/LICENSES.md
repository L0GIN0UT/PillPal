# Catalog sources: terms and attribution

The catalog holds public reference data only. Every source has a row in `catalog.sources` (`license`,
`attribution`, `url`, seeded by migration `c0002`); `GET /v1/sources` (milestone 4.5) serves it to the
Settings -> About screen. This file keeps the terms behind those rows and the exact attribution strings.

Status of the entries below: written in milestones 4.4 and 4.4b from the sources' published terms, **without a
legal review**. Re-read the linked pages and have counsel confirm before the first public launch
(`docs/phase4-plan.md`, "Legal review required before launch"). Fixtures in `catalog/tests/fixtures/` are
synthetic (invented names, rxcuis, NDCs and GTINs) and carry no source data.

## openFDA National Drug Code directory (`openfda_ndc`, importer `openfda_ndc.py`)

- Data: the bulk `drug-ndc` files listed in `https://api.fda.gov/download.json`
  (`https://download.open.fda.gov/drug/ndc/`). Each file carries its own `meta.license`
  (`https://open.fda.gov/license/`) and `meta.terms` (`https://open.fda.gov/terms/`).
- Terms: openFDA data are a work of the U.S. Government released under CC0 1.0 (public domain dedication),
  except where a record says otherwise. openFDA asks users not to suggest that the FDA endorses the product
  and to say that the data must not be relied on for medical decisions.
- Caveats from the publisher: the NDC directory is self-reported by labelers, is not a complete list of
  marketed drugs and may contain errors. PillPal therefore never treats a catalog row as medical advice; it
  is a convenience for filling in a medication.
- Attribution string (app, `sources.attribution`): `Product data: openFDA (U.S. FDA)`.
- Recommended About text next to it: "Not for clinical decisions. The FDA does not endorse this application."
- What the importer takes: finished, human prescription and OTC products only; product and package NDCs,
  labeler, dosage form, active ingredients with strengths, `openfda.rxcui`. NDC -> GTIN-14 follows
  `docs/spec/gtin.md` section 6.2.
- Download policy: https only, host allow-list (`api.fda.gov`, `download.open.fda.gov`), byte cap per file,
  archive guards. openFDA publishes no checksums, so `fetch` reports the sha256 of the resulting snapshot.

## RxNorm Prescribable Content (`rxnorm`, importer `rxnorm.py`)

- Data: `RxNorm_full_prescribe_<MMDDYYYY>.zip` (monthly) from `https://download.nlm.nih.gov/rxnorm/`; the
  importer reads `RXNCONSO.RRF`, `RXNREL.RRF`, `RXNSAT.RRF` and `RXNSAB.RRF` (version) from `rrf/`.
- Terms: RxNorm is produced by the U.S. National Library of Medicine (NLM). The Prescribable Content subset
  contains only RxNorm's own (public) vocabulary atoms and is distributed without a UMLS license; NLM terms
  require attribution and the disclaimer below. Source vocabularies of the full release (for example
  proprietary drug databases) are not in this subset, and the importer keeps only atoms whose source
  vocabulary is `RXNORM`.
- Attribution string (app, `sources.attribution`):
  `Substance and composition data: RxNorm, U.S. National Library of Medicine`.
- Full statement, shown in About: "This product uses publicly available data courtesy of the U.S. National
  Library of Medicine (NLM), National Institutes of Health, Department of Health and Human Services. NLM is
  not responsible for the product and does not endorse or recommend this or any other product."
- What the importer takes: ingredients (IN) and precise ingredients (PIN) as substances; semantic clinical
  drugs (SCD) with their components (SCDC) and dose forms (DF) as compositions, strengths from
  `RXN_BOSS_STRENGTH_*` (fallback `RXN_AVAILABLE_STRENGTH` for single-ingredient SCDs). No products.
- Download policy: https only, host `download.nlm.nih.gov`, byte cap, archive guards; `--expect-sha256` pins
  the archive, `--release MMDDYYYY` pins the dated release (otherwise the `current` alias is fetched).

## ESKLP (`esklp`, importer `esklp.py`) - shipped disabled

- Data: the unified state catalog of medicines (КЛП trade items + СМНН INN/form/strength), downloaded by the
  owner from `https://esklp.egisz.rosminzdrav.ru/` (the XML/ZIP export, schema 21.5, or an xlsx file). Barcodes
  exist only for ЖНВЛП packs with a registered price (about 10% of КЛП).
- Terms: **no license text has been found** (`docs/research/ru-sources.md` section 2). The importer therefore
  refuses every operation unless `CATALOG_IMPORTER_ESKLP_ENABLED=true`. **Legal status: unverified.** Before the
  flag is set: (1) confirm that the file downloads without authentication, (2) send the written request to
  Минздрав / ЦНИИОИЗ on use in a commercial app, (3) get answers to legal review items 1-2.
- Attribution string (wording to confirm): `Data: ESKLP, Ministry of Health of Russia` (in Russian
  `Данные: ЕСКЛП, Минздрав России`).
- What the importer takes: trade name, INN, form, dosage, manufacturer **name** and country, registration
  number, barcode, pack wording, KLP and SMNN identifiers. It does not read the manufacturer's address or any
  other column. A manufacturer that is an individual entrepreneur (`ИП ...`, `Глава КФХ ...`) is a natural person:
  its name is not stored (`manufacturer` stays empty, counted as `manufacturer_individual`); legal entities keep
  the name as published.
- Download policy: https only, host allow-list (`esklp.egisz.rosminzdrav.ru`), the URL is supplied by the
  operator (`--url`), byte cap, optional `--expect-sha256`, archive guards, nothing kept on failure, the stored
  file is read end to end once. No page is scraped. The portal's certificate chains to the Russian Trusted Root
  CA: the operator adds it from a file (`CATALOG_IMPORTER_RU_CA_FILE`) for this host only, on top of certifi.
- Format status: the XML side follows the official schema `ESKLP_21.5.xsd`; the xlsx header wording is
  **verified on synthetic fixtures only**. Smoke-import a real file before relying on it.

## Roszdravnadzor open data (`ru_roszdravnadzor`, importer `ru_roszdravnadzor.py`)

- Data: the open-data set "drugs_qualitycontrol" (quality-control decisions on series), one CSV file, URL
  chosen by the operator from `https://roszdravnadzor.gov.ru/opendata/7710537160-drugs_qualitycontrol` (the
  data file name changes weekly).
- Terms (as quoted in `docs/research/ru-sources.md` section 4, **not legally reviewed**): the user may reuse the
  open data freely, for free, perpetually and commercially, must keep the link to the source and must not
  distort the data.
- Attribution string (app, `sources.attribution`): `Data: Roszdravnadzor (open data)`.
- Gate: recall flags attach to ESKLP products, so `fetch` and `run` refuse unless `CATALOG_IMPORTER_ESKLP_ENABLED=true`
  (docs/phase4-plan.md 4.4b), although the list itself has an open license.
- What the importer takes: registration number (`no_ru`), series, a reason **code** (`substandard`,
  `counterfeit`, `withdrawn`, `suspended`) and the letter date, and only for rows whose status and decision type
  are both negative (allow-lists in `ru_roszdravnadzor.py`); confirmations (`оригинальное ЛС`, release
  permissions) and suspicions (`сомнительное ЛС`) are skipped and counted. Trade name, producer, letter number
  and the decision wording are not stored. Flags are never deleted by an import. The card shows recalled series
  as a neutral note for manual comparison with the pack.
- Download policy: https only, host allow-list (`roszdravnadzor.gov.ru`, `www.roszdravnadzor.gov.ru`), byte cap,
  optional `--expect-sha256`, HTML or archive downloads refused, nothing kept on failure.
- Format status: columns and values checked against the real file (2026-11, ~42 500 rows); fixtures are
  synthetic.

## GRLS manual export (`grls_manual`, importer `grls_manual.py`) - shipped disabled

- Data: the Excel export of a search on `https://grls.rosminzdrav.ru/`, downloaded by the owner by hand once a
  month, saved as `.xlsx` and passed with `--snapshot`.
- Terms: the Ministry's site terms (2014) allow copying with a link but state that the information may not be
  used for commercial purposes; there is no bulk dump or API (`docs/research/ru-sources.md` section 1). The
  importer refuses unless `CATALOG_IMPORTER_GRLS_ENABLED=true`. **Legal status: unverified; research questions
  Q3-Q4 must be answered first.**
- Attribution string: `Data: GRLS, Ministry of Health of Russia`.
- What the importer takes: registration number and barcode(s). No network code exists in the importer; there is
  no `fetch`. It creates no product or package and never withdraws a row.

## EMA medicines data (`ema`, importer `ema.py`)

- Data: the "Medicines output: European public assessment reports" workbook of centrally authorised medicines,
  published on `https://www.ema.europa.eu/en/medicines/download-medicine-data`. `fetch` requests the report
  address in `ema_fetch.DEFAULT_URL` (**unverified**) unless the operator passes `--url`.
- Terms: EMA's legal notice allows reuse of its documents and data with acknowledgement of the source and
  without distortion. **Legal status: unverified.** Before the first public launch, re-read the legal notice and
  the dataset's own page, confirm that the medicines report is covered (and that database rights are not
  reserved), and have counsel confirm the attribution wording (`docs/phase4-plan.md`, legal review).
- Attribution string (app, `sources.attribution`): `Product data: European Medicines Agency`. EMA asks users
  not to suggest endorsement; the About text should say the data are informational, not for clinical decisions.
- What the importer takes: medicine name, active substance(s), product number, authorisation status, category
  and the marketing authorisation holder (stored as `manufacturer`: a company). Only human medicines with the
  status `Authorised` are kept; withdrawn, suspended and refused ones are counted and withdrawn from the catalog
  by the next run. EMA publishes no strength, dosage form, pack or GTIN, so every composition is **incomplete**
  (substances only, never `complete = true`) and feeds the overlap hint only.
- Download policy: https only, host allow-list (`www.ema.europa.eu`, `ema.europa.eu`), byte cap, optional
  `--expect-sha256`, anything that is not a workbook refused, nothing kept on failure, the stored file is read
  end to end once. No page is scraped.
- Format status: **synthetic only.** Header wording, title rows above the header and status values were written
  from memory of the public file; smoke-import the real file (catalog/README.md, "EMA (4.8)").

## Wikidata (`wikidata`)

Seeded in `sources` (CC0) but **no importer in 4.4b** (see ADR 0012 section 4).

## Parsing dependencies

Phase 4.4 adds no parser dependency: JSON is read by `catalog/importers/jsonstream.py` and RRF by
`catalog/importers/rrf.py` (both standard library only). Milestone 4.4b adds none either: xlsx is read by
`catalog/importers/xlsx.py` (`zipfile` + `xml.etree`, no formulas evaluated, caps on parts, ratio, sheets, rows,
columns, cell length and shared strings; a DOCTYPE or entity declaration is refused by
`catalog/importers/safe_xml.py`) and CSV by the standard `csv` module. `openpyxl` was considered and not added:
it brings a dependency tree for a read-only subset of the format and gives less control over the limits. The EMA importer (4.8) reads its workbook with the same reader, so `openpyxl` stays out (ADR 0012 planned it for 4.8; the stdlib reader with hard limits replaced it). `httpx` (BSD-3-Clause), already a development
dependency, is now a runtime dependency for `fetch`.
