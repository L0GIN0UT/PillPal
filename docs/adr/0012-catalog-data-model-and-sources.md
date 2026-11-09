# ADR 0012 — Catalog data model, identity and sources (Phase 4)

- Status: accepted
- Date: 2026-10-21
- Scope: TZ §2.1 (four-level model, identity = full composition + form, sources, "один
  продукт может иметь несколько GTIN"), §6 (ЕСКЛП license); `catalog/catalog/db/models.py`,
  `catalog/catalog/domain/identity.py`, `catalog/catalog/importers/*`, `catalog/LICENSES.md`,
  revisions `c0002_catalog_core`, `c0003_search_entries`
- Related: owner decisions D1 and D6 (`docs/phase4-plan.md`), ADR 0011 (service boundary),
  ADR 0013 (GTIN contract), ADR 0014 (consensus rows), `docs/research/ru-sources.md`
  (RU open sources research, milestone 4.4b), `.claude/rules/privacy.md` rule 9

## Context

The TZ fixes a four-level model — Substance (INN) → Composition (substances with strengths
plus a dosage form) → Product (trade name, country, manufacturer) → Package (GTIN,
count) — and says identity is the full composition plus form (Терафлю ≠ Фервекс). Sources
differ per market: RxNorm Prescribable Content and openFDA NDC for the US, EMA for the EU,
ЕСКЛП/ГРЛС for Russia (license not confirmed, TZ §6), plus user GTIN links. The owner
decided (D1) not to block Phase 4 on the ЕСКЛП license: the ЕСКЛП importer is built
behind a flag (`CATALOG_IMPORTER_ESKLP_ENABLED=false`) together with an importer of the openly
licensed Росздравнадзор data, and RU users meanwhile get foreign products labelled by
country, and (owner decision at planning) **not to match or merge products across
markets automatically** at the start.

Catalog ids are referenced from user medications in every region (ADR 0015) and from the
device cache, so they must be stable across re-imports and identical in every deployment.
User medications may reference a product that a later import withdraws, so rows must never
disappear.

## Decision

### 1. Four levels, per source, no cross-market merge

| Level | Table | Source key examples | Notes |
|---|---|---|---|
| Substance | `substances` | RxNorm IN/PIN rxcui, UNII, EMA substance name, RU source key | `name_en`, `name_ru` (nullable); INN mapping only where the source carries a UNII, rxcui or English INN |
| Composition | `compositions` + `composition_ingredients` | RxNorm SCD rxcui; otherwise source-local | `form_code`/`form_name_*`; `complete` is true only when every ingredient has a strength and the form is set; CHECK `complete ⇒ form_code IS NOT NULL` |
| Product | `products` | openFDA `product_ndc`, EMA product number, RU source key | `market` ∈ {`ru`,`us`,`eu`}, `brand_name`, `manufacturer` (MAH), `country`, `rx_status` |
| Package | `packages` + `gtins` | openFDA `package_ndc`, consensus `gtin-pkg:<gtin>` | one product → many packages → many GTINs; `gtins.gtin` is a 14-digit PK with the check-digit and shareable CHECKs of ADR 0013 |

- A composition is identified **within a source** by `identity_key = sha256` of the canonical
  ingredient set (sorted substance ids with normalized strength value/unit and per
  value/unit) plus the form code. Two sources describing the same composition produce two
  rows; "same composition" (ADR 0015 §6) therefore only fires within one source and market.
  Cross-market matching is a possible later feature with its own ADR.
- `market` on products and `country` on products are distinct: `market` is the regulator's
  market the source covers; `country` is the manufacturer's country shown to the user (D6
  labelling uses `country`, ranking uses `market`).
- Incomplete compositions (EMA, RU sources without structured strength) feed the substance
  overlap hint only, never "same composition".

### 2. Deterministic ids: UUIDv5

`id = uuid5(CATALOG_NAMESPACE, f"{source}:{kind}:{source_key}")` with
`CATALOG_NAMESPACE = uuid5(NAMESPACE_URL, "https://pillpal.invalid/catalog/v1")` pinned in
`catalog/catalog/domain/identity.py` and asserted by a test. Consensus packages use
`uuid5(CATALOG_NAMESPACE, "consensus:package:gtin-pkg:<gtin14>")`. Consequences:

- a re-import of the same snapshot is a no-op; every regional deployment computes the same
  ids (ADR 0011 §3);
- the namespace string is part of the contract: changing it would orphan every user
  reference, so it is never changed; a model change that needs new ids goes through a new
  `kind` name;
- catalog rows are **not** user entities: the sync rule "client-generated UUIDs" is about
  medications, schedules and dose events, which reference catalog ids as opaque values.

### 3. Imports: snapshot, upsert, withdraw, never delete

- `import_runs` records source, source version, snapshot sha256, status and counts; a
  partial unique index allows one `running` run per source.
- A run loads records into staging temp tables, upserts by id, marks rows absent from the
  snapshot with `withdrawn_at` (they stay resolvable by id and are excluded from default
  search, shown with a label), rebuilds `search_entries` for the source, and commits once.
  A failed run leaves the previous state intact.
- Rows are never deleted by an import. A source that disappears is disabled in `sources`;
  its rows stay withdrawn.
- Fixtures are synthetic and format-faithful (privacy rule 9): invented rxcuis, NDCs with
  valid check digits, names like "Testamol" / "Тестамол". Real snapshots are a manual
  checklist item.

### 4. Sources and licensing

| Source | Market | Importer | Milestone | License / terms (status) | Attribution shown in the app |
|---|---|---|---|---|---|
| openFDA NDC (bulk `drug-ndc` JSON) | us | `openfda_ndc` | 4.4 | US government work, stated as public domain / CC0 by openFDA; disclaimer "not for clinical decisions" — **to verify in 4.4** against `open.fda.gov/terms` | "Product data: openFDA (U.S. FDA)" |
| RxNorm Prescribable Content (RRF) | us | `rxnorm` | 4.4 | NLM terms: attribution and disclaimer; the Prescribable subset is distributed without the UMLS license per NLM documentation — **to verify in 4.4** | "Substance and composition data: RxNorm, U.S. National Library of Medicine" |
| **ЕСКЛП** (state catalog, xlsx/XML per the official passport: КЛП + СМНН incl. `barcode`) | ru | `esklp` | 4.4b | published for download at `esklp.egisz.rosminzdrav.ru`, but **no license text found anywhere** (`docs/research/ru-sources.md`); the only state source with trade name, INN, form, strength, manufacturer and barcode in one file. The importer is real but runs only with `CATALOG_IMPORTER_ESKLP_ENABLED=true`, which is the owner's act after the checklist (file downloads without authentication; written request to Минздрав/ЦНИИОИЗ). Legal questions Q1–Q3 of the research | "Data: ЕСКЛП, Минздрав России" (wording to confirm) |
| Росздравнадзор open data (`roszdravnadzor.gov.ru/opendata`) | ru | `ru_roszdravnadzor` | 4.4b | explicit open license: free, perpetual, commercial use allowed, source link required, no distortion. Holds no catalog; used only for **recalled / rejected series flags** on products | "Data: Росздравнадзор (open data)" |
| ГРЛС (`grls.rosminzdrav.ru`) | ru | `grls_manual` | 4.4b | **manual monthly Excel export only**, no scraping, no automated crawling. Minzdrav site terms (2014) forbid commercial use of site content, so this path is incremental (new registrations, registration status, EAN not in КЛП) and is gated like ЕСКЛП (research questions Q3–Q4). The open-data CSV of ГРЛС is from 2017 and is not imported | "Data: ГРЛС, Минздрав России" |
| Wikidata (CC0) | ru/eu | optional enrichment | 4.4b (optional) | CC0; INN/ATC and RU/EN synonyms only, almost no Russian brands. Never a source of products | none required |
| Честный знак / Национальный каталог / Vidal / РЛС | ru | — | rejected | contract or participant status required; no public GTIN lookup; site terms forbid scraping and commercial reuse. Not used | — |
| EMA medicines data (EPAR report) | eu | `ema` | 4.8 | EMA legal notice: reuse permitted with acknowledgement of the source — **to verify in 4.8** for the specific dataset | "Product data: European Medicines Agency" |
| Consensus (user GTIN links) | per region | `consensus` | 4.7 | aggregates only (ADR 0014); no license | "Package links confirmed by PillPal users" |

- `sources` rows carry `license`, `attribution` and `url`; `GET /v1/sources` returns them for
  the Settings → About screen, and `catalog/LICENSES.md` keeps the full terms text.
- Dependencies for parsing (`openpyxl` for EMA, archive handling) are pinned and their
  licenses recorded in `catalog/LICENSES.md`.

### 5. Search and ranking (D6)

`search_entries` holds one row per entity, market and language with `norm` (lower,
unaccent, ё→е) and a `simple`-configuration `tsvector`; GIN indexes on `tsv` and on `norm`
with `gin_trgm_ops`. Score = ts_rank + trigram similarity + own-market boost + source
authority − withdrawn penalty, ties by id. **Own-market products rank first; foreign-market
products follow, each with `country` for the app's label** (D6). No transliteration, no
cross-market synonyms, no popularity signal.

## Consequences

- Six content tables plus `search_entries` and the consensus tables of ADR 0014; revisions
  `c0002`, `c0003` (and a sources seed revision in 4.4b).
- Users may link products from any market; RU users see US/EU products labelled by country
  until the ЕСКЛП importer is enabled by the owner (4.4b ships it disabled), then RU
  products first.
- Two sources describing the same medicine are two products; the "same composition" prompt
  does not bridge them. This is intended at the start.
- ЕСКЛП carries structured strength and form (СМНН), so RU compositions can be
  `complete = true` once the flag is on; until then there is no RU product data except
  recall flags, and RU users rely on foreign products (D6) and "scan to remember".
- Legal questions Q1–Q7 of `docs/research/ru-sources.md` are collected in the plan's
  "Legal review" list; none of them blocks the code, only the flag.
- Withdrawn rows accumulate; this is accepted (public data, small tables).

## Alternatives considered

- **Cross-source matching by INN + strength + form** into one global composition: better
  analog detection, but the strength and form vocabularies differ per source and a wrong
  merge would produce a false "same composition" prompt; deferred.
- **Random UUIDs with a mapping table**: would need coordination between regional catalogs
  and a persisted mapping; UUIDv5 needs neither.
- **Deleting withdrawn rows**: would break user references and the device cache.
- **Waiting for ЕСКЛП before building any RU importer** (the planner's original default):
  rejected by the owner (D1); the importer is built and flag-gated instead.
- **Importing ЕСКЛП unconditionally**: no license text exists, so enabling it is the owner's
  act after the written request is answered.
- **Scraping ГРЛС or Национальный каталог pages**: excluded; ГРЛС enters only through a
  documented manual monthly Excel export. Честный знак / Национальный каталог / Vidal / РЛС
  need contracts and are rejected.
