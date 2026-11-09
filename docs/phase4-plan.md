# Phase 4 — Catalog and scanning («Справочник и скан») — delivery plan

Source: `docs/TZ.md` §1 (regions; the catalog is a global service without personal data), §2.1, §3, §5 "Фаза 4", §6 (ЕСКЛП license, no OCR). Rules: `.claude/rules/privacy.md`, `security.md`, `testing.md`, `coding-style.md`.
ADRs: 0011 (catalog service boundary and deployment), 0012 (data model, identity, sources and licensing), 0013 (GTIN and scanning contract), 0014 (GTIN link consensus), 0015 (app integration and catalog traffic privacy). Owner decisions D1–D9 (2026-10-21, D1 refined 2026-10-22, D9 2026-11-09) are in the section "Owner decisions" at the end of this file and are propagated through it.
Baseline: `main` = `b40b5bb` (4.1 merged, PR #25). Phases 1–3 are done. Milestone status is in the table below.

Constraints:
- Flutter/Dart does not run in the Claude sandbox, so CI verifies it. A new app dependency means: edit `app/pubspec.yaml`, delete `app/pubspec.lock` in the same commit, then pull the `app-scaffold.yml` lockfile commit.
- Backend and catalog tests run on real PostgreSQL 16 (plus Redis 7 where used). Only true externals are mocked: source downloads, and the backend→catalog HTTP call through `httpx.MockTransport`.
- A personal RU staging stack already has field-test APKs installed (`docs/staging.md`). So every protocol change must be **backward compatible with installed clients**, and that rules out one-step breaking changes. The staging stack itself stays as it is until milestone 4.12 adds the catalog service to it.
- No Phase 5 work beyond the appendix proposal: no OAuth, payments, export, analytics SDK, regional routing, store or production deployment work.
- Each milestone is one PR into `main`, merged only with green CI, in table order. App milestones touching `app-emulator.yml` or `.github/scripts/emulator/` go one at a time.

## Requirements (restated)

- **Four-level drug model.** Substance (INN) → Composition (a set of substance + strength, plus a dosage form) → Product (brand, country/market, manufacturer) → Package (GTIN(s), count). A medicine's identity is its full composition plus form, so Терафлю ≠ Фервекс. **No automatic matching or merging across markets at start** (owner decision): products from different sources and markets stay distinct.
- **Global catalog service with no personal data.** It holds sources, an import pipeline, search (ru/en, by brand, INN or GTIN, typo-tolerant, ranked by market), GTIN lookup and consensus. Its code and data are global, and it can be deployed per region or globally.
- **Medications keep their free text** and gain optional catalog references that sync like other fields. The app works without the catalog: search needs a network, linked products are cached on the device, and a scanned GTIN is remembered on the medication itself.
- **Input methods:** free text, catalog autocomplete, and package scan (EAN-13 / UPC-A / GS1 DataMatrix, including Честный знак). Manual GTIN entry is the fallback. GTINs are normalized to GTIN-14. Restricted-circulation numbers never reach the shared base. Serial and lot never leave the parser.
- **GTIN→product links** come only from choosing a catalog product. A link becomes shared after N matching confirmations. Disputed links go to an admin, through endpoints plus a CLI with no UI. A manual composition stays private.
- **On add:** the same composition offers to link the package to an existing medication. A substance overlap shows a neutral hint, "both contain X". Creating a separate medication is always possible. Ads never appear here.
- **RU data without waiting for a license text (D1).** ЕСКЛП is the only state source with brand, INN, form, strength, manufacturer and barcode in one file, but it has no published license text. The ЕСКЛП importer is therefore built (milestone 4.4b) and ships **disabled** behind `CATALOG_IMPORTER_ESKLP_ENABLED=false`; the Росздравнадзор open-data importer (explicit open license) supplies recalled-series flags; ГРЛС enters only by a documented manual monthly Excel export. Details: `docs/research/ru-sources.md`, ADR 0012 §4.

## Assumptions

- Catalog ids are **deterministic UUIDv5** of `(source, kind, source_key)` under a fixed namespace pinned in ADR 0012. Re-imports and every regional deployment then produce the same ids without coordination. The rule "ids are client UUIDs" still holds for user entities: catalog rows are not user entities, and users never create them.
- The regional backend stores catalog references as **opaque UUIDs without foreign keys**, because the catalog is a different database and service. The backend never calls the catalog on the request path.
- A Честный знак code is parsed **on the device**. Only the GTIN-14 is ever sent over the network.
- The ЕСКЛП importer exists but is enabled only by the owner after the checklist in 4.4b (TZ §6; D1). Until it is enabled, RU users get US/EU catalog data (labelled by country, D6) plus "scan to remember" (the GTIN stored privately on the medication). Recall flags attach to ЕСКЛП products by registration number, so they need the flag too.
- `docs/TZ.md` and `README.md` are not edited.

## Key decisions (fixed in ADRs 0011–0015)

1. **The catalog is a separate uv project, `catalog/`, at the repo root (ADR 0011).** It has its own `pyproject.toml`/`uv.lock`, Alembic, Dockerfile, image `pillpal-catalog`, database and CI workflow `catalog.yml`. Why not a second entrypoint inside `backend/`:
   - **(a) Hard privacy boundary.** The catalog image contains no users, tokens, JWT secret or personal-data models, so "the catalog holds no personal data" can be shown by construction, not only by review.
   - **(b) Separate deploy topology.** It can run global or per region, and its import cadence is independent of the backend.
   - **(c) Smaller attack surface for the backend.** Importer dependencies (zip/xlsx parsing) stay out of the backend image.
   - **(d) Build context.** The Docker build context of `backend/` cannot include path dependencies.
   - **Cost:** about 300 lines of logging, error-envelope and rate-limit code are copied (accepted, noted in the ADR). The GTIN normalize/shareable rule exists in three implementations (catalog Python as reference, backend Python subset, Dart), all guarded by shared vectors. This is the same discipline as `schedule-vectors`.
   - **Default deployment: one catalog per region (D2)**, next to the regional stand. Each regional catalog imports the same public sources, so ids are identical. User contributions stay in their region, matching "no cross-region links" and 152-FZ optics. A single global deployment is supported by the same image (`region` is a column on contribution data).
2. **Catalog traffic is unlinkable to accounts (ADR 0015).**
   - The app calls the catalog directly with **no Authorization header and no backend `X-Device-ID`**. It sends only a catalog-only random install id (`X-Catalog-Install`, rotated every 30 days), used for rate limiting.
   - All lookups are `POST` with JSON bodies, so search strings, GTINs and product ids never appear in URLs or proxy logs.
   - Access logs carry the route template, status and latency only. Rate-limit keys are salted hashes with a short TTL.
   - PostgreSQL statement and parameter logging is off for the catalog database.
3. **Consensus without identifiers (ADR 0014).**
   - Confirmations are counted **in the regional backend**: distinct verified profile owners whose live medication carries `(gtin, catalog_product_id)` with the owner's opt-in `gtin_link_shared = true` (D2: per-link checkbox at link time, default off).
   - The backend sends the catalog **only aggregates** `{gtin, product_id, count}` per region, as a paged full snapshot, using a per-region service token (D2).
   - The catalog stores no user, device or pseudonym. Sybil resistance comes from accounts: verified e-mail, not `pending_deletion`, account age ≥ 7 days (D8).
   - Erasure and opt-out work automatically: the next snapshot lowers the counts.
   - A pure function `decide()` turns counts and official data into `promoted | disputed | pending` with N = 3 and dispute at 2 (D8).
4. **Medication references are fields, nothing else (ADR 0015).**
   - New optional fields: `catalog_product_id`, `catalog_package_id`, `catalog_composition_id`, `gtin`, `gtin_link_shared`, `manual_ingredients`.
   - In sync push they use **keep-on-absent** semantics: absent means "keep", explicit `null` means "clear". This is the `ProfileData.mutable_fields` pattern, needed so installed staging APKs do not wipe the fields.
   - LWW, tombstone erasure and privacy classification all extend the existing code.
5. **Scanner: `mobile_scanner`, exact version pinned (ADR 0013).**
   - License BSD-3-Clause; latest stable `7.4.2` (2026-09-14) at the time of writing, re-checked at 4.11. Android uses the **bundled** ML Kit model (the plugin's default), so devices without GMS (RuStore users) work. iOS uses AVFoundation + Apple Vision.
   - ML Kit sends usage metrics to Google (ML Kit terms); images and decoded values stay on the device. This is listed as a third party and is a legal item.
   - Alternative recorded in the ADR: `flutter_zxing` (MIT; zxing-cpp, fully offline). Switch to it if legal objects to ML Kit metrics.
   - GS1 parsing happens in `pillpal_core`, never in the plugin.
6. **Same composition and substance overlap are computed on the client** in `pillpal_core` (pure Dart) from cached catalog data of the profile's medications. "Same composition" means equal `composition_id` and the composition is complete. Overlap uses catalog substance ids only, never free text, to avoid false hints. There is **no analog list or analog hint** (D9).
7. **Sources and licensing (ADR 0012):**
   - Ships first: openFDA NDC (CC0) and RxNorm Prescribable Content (NLM, attribution).
   - Then **RU sources (D1, milestone 4.4b)**, chosen in `docs/research/ru-sources.md`:
     - **ЕСКЛП** importer (xlsx/XML per the official passport schema: КЛП + СМНН, including `barcode`) behind `CATALOG_IMPORTER_ESKLP_ENABLED=false`. It refuses to run while the flag is false; setting it is the owner's act (checklist in 4.4b);
     - **Росздравнадзор opendata** importer (explicit open license, attribution) for recalled-series flags only;
     - **ГРЛС** only through a documented manual monthly Excel export, never scraping;
     - **Wikidata** (CC0) optional INN enrichment;
     - **Rejected:** Честный знак / Национальный каталог / Vidal / РЛС (contract only; scraping forbidden).

     Attribution and terms go into the licensing table of ADR 0012 and `catalog/LICENSES.md`.
   - Second: EMA.

### ADR list
- **0011** — Catalog service boundary and deployment (separate project, per-region default, no personal data by construction, duplicated helpers, threat model).
- **0012** — Catalog data model, identity and sources (four levels, per-source compositions, no cross-market merge, UUIDv5 namespace, withdrawn rows, licensing table incl. ЕСКЛП behind a flag, Росздравнадзор, manual ГРЛС).
- **0013** — GTIN and scanning contract (normalization, restricted numbers per D3 with GS1 citations, GS1/ЧЗ parsing, serial/lot never stored or sent, expiry parsed not stored per D7, scanner package and permissions).
- **0014** — GTIN link consensus (regional aggregation, opt-in per D2, thresholds per D8, disputes, admin tokens, CLI, audit).
- **0015** — App integration and catalog traffic privacy (medication fields, keep-on-absent, cache, unlinkable requests, fill-empty-only per D5, link-to-existing per D4, foreign-market labelling per D6, overlap hint).

---

## Data model

### Catalog database (global, public data only) — `catalog/catalog/db/models.py`, revisions `c0001…`

| Table | Key columns | Constraints and indexes |
|---|---|---|
| `sources` | `code` PK (`rxnorm`,`openfda_ndc`,`ema`,`esklp`,`ru_roszdravnadzor`,`grls_manual`,`wikidata`,`consensus`), `name`, `license`, `attribution`, `url`, `enabled` | seeded once, in `c0002` (arch N5) |
| `import_runs` | `id` uuid, `source` FK, `source_version`, `snapshot_sha256`, `status` (`running`,`succeeded`,`failed`), `started_at`, `finished_at`, `counts` jsonb, `error_code` | one `running` per source (partial unique) |
| `substances` | `id` (uuid5), `source`, `source_key` (RxNorm IN rxcui, UNII, EMA substance, RU source key), `market`, `name_en`, `name_ru` null, `withdrawn_at`, `last_run_id` | UNIQUE `(source, source_key)` |
| `substance_names` | `substance_id`, `lang`, `name`, `source` | PK `(substance_id, lang, name)`; feeds `search_entries` so «ибупрофен» finds foreign products through substance → products; RU INN names are mandatory for every substance an RU or Wikidata source maps |
| `compositions` | `id`, `source`, `source_key` (source-native key: SCD rxcui, or the source's own key for source-local compositions; never derived from the ingredient set), `market`, `form_code`, `form_name_en`, `form_name_ru`, `complete` bool, `identity_key` (sha256 of the canonical ingredient set + form), `withdrawn_at` | UNIQUE `(source, identity_key)`; CHECK `complete ⇒ form_code IS NOT NULL` |
| `composition_ingredients` | `composition_id`, `substance_id`, `strength_value` numeric null, `strength_unit`, `per_value`, `per_unit` | PK `(composition_id, substance_id)`; CHECK `strength_value > 0`; the loader enforces "complete ⇒ every strength set", and a test covers it |
| `products` | `id`, `source`, `source_key` (openFDA product_ndc…), `market` CHECK in (`ru`,`us`,`eu`), `brand_name`, `manufacturer`, `country`, `composition_id` FK null, `rx_status`, `registration_number` null, `withdrawn_at` | UNIQUE `(source, source_key)`; index `(composition_id)`, index `(registration_number)` |
| `recall_flags` | `registration_number`, `series`, `reason_code`, `source`, `published_at` | PK `(registration_number, series, source)`; public regulatory data; the card lists recalled series for manual comparison with the pack (the lot is discarded by the parser, so the app never matches) |
| `packages` | `id`, `product_id` FK, `source`, `source_key`, `description`, `count` numeric null, `count_unit` null, `withdrawn_at` | UNIQUE `(source, source_key)` |
| `gtins` | `gtin` char(14), `source`, `package_id` FK, `origin` CHECK in (`source`,`consensus`,`admin`), `created_at` | PK `(gtin, source)`; precedence on lookup: admin lock > official source by source authority > consensus; rows are withdrawn per source; | CHECK `gtin ~ '^[0-9]{14}$' AND catalog.gtin_check_digit_ok(gtin) AND catalog.gtin_is_shareable(gtin)`, so restricted numbers cannot enter even by bug. One product can have many packages and GTINs |
| `search_entries` | `entity_kind` (`product`,`substance`), `entity_id`, `market`, `lang`, `text`, `norm` (lower + unaccent + ё→е), `tsv` | GIN `(tsv)`, GIN `norm gin_trgm_ops`; rebuilt per import run in the same transaction |
| `gtin_link_candidates` | `region`, `gtin`, `product_id` FK, `confirmations` int, `generation`, `reported_at` | PK `(region, gtin, product_id)`; CHECK `confirmations ≥ 2` (the backend sends only counts ≥ 2, privacy S1); same GTIN CHECKs |
| `gtin_link_decisions` | `gtin` PK, `status` (`pending`,`promoted`,`disputed`,`rejected`,`locked`), `product_id` null, `decided_by` (`auto`,`admin`), `decided_at`, `reason_code` | |
| `admin_audit` | `id`, `at`, `admin_name`, `action`, `gtin`, `product_id` | no personal data; the admin name is a token label |

- Extensions: `pg_trgm`, `unaccent`, plus an IMMUTABLE wrapper for index use.
- Withdrawn rows stay resolvable by id, because user medications reference them. They are excluded from default search and shown with a label.
- Deleting catalog rows is not part of any import.

### Regional backend — changed table `medications` only

| Column | Type | Constraint | Revision |
|---|---|---|---|
| `catalog_product_id`, `catalog_package_id`, `catalog_composition_id` | uuid null | no FK (other database) | `0014_medication_catalog_refs` |
| `gtin` | text null | CHECK `gtin ~ '^[0-9]{14}$'` (restricted GTINs are allowed: private to the user) | same |
| `gtin_link_shared` | bool NOT NULL DEFAULT false | CHECK `NOT gtin_link_shared OR (gtin IS NOT NULL AND catalog_product_id IS NOT NULL)`; CHECK `deleted_at IS NULL OR NOT gtin_link_shared` | same |
| `gtin_link_consent_version`, `gtin_link_consented_at` | int null, timestamptz null | version sent by the app (the text it displayed, validated against the server's supported set), timestamp server-set, when `gtin_link_shared` becomes true; CHECK both null when not shared | same |
| `manual_ingredients` | jsonb null | CHECK `jsonb_typeof = 'array'` and `jsonb_array_length ≤ 10`; items `{substance_id?, name ≤100, strength_text ≤50}` validated by Pydantic | `0015_med_manual_ingredients` |

- `MEDICATION_CONTENT` gains the five content fields; **`gtin_link_shared` and the two consent columns stay out of it**. Tombstoning sets `gtin_link_shared = false` and nulls the consent columns; the CHECK `deleted_at IS NULL OR NOT gtin_link_shared` enforces it. The `tombstone_erased` CHECK change (`ADD … NOT VALID`, then `VALIDATE`) is made in the **first** revision `0014`, not split across two (arch B1, N5).
- **Consent follows the pair, not the row.** The server resets `gtin_link_shared = false` and clears the consent columns whenever `gtin` or `catalog_product_id` changes, unless the same upsert comes from a full-access role and explicitly sets it true (privacy B1, arch B3). Editors may re-link but never carry consent. CHECK violations map to `422`.
- Partial index `(gtin, catalog_product_id) WHERE gtin_link_shared AND deleted_at IS NULL` serves the aggregator.
- `services/personal_data.py`: `medications` is already `medical`, and the new columns are covered by the row. The needle test asserts that the columns are erased.
- Expiry dates (GS1 AI 17) are **not stored** anywhere (D7): no column, no local field.

---

## Importer design (`catalog/catalog/importers/`)

- **Protocol** `Importer` (`base.py`):
  - `source: SourceCode`, `license: LicenseNote`;
  - `fetch(dest) -> SnapshotManifest` (network; records URL, version/date, sha256, retrieval time);
  - `parse(snapshot_dir) -> Iterator[Record]` (pure, no DB, tested on fixtures);
  - one shared `load(session, records, run)`: staging temp tables, then upsert by deterministic id, then mark missing rows `withdrawn_at` (skipped when `withdraw_missing=False`, used by the manual ГРЛС path), then rebuild `search_entries` per changed entity, all in one transaction per run.
- **Reproducible.** `python -m catalog.importers fetch --source X --out DIR` and `python -m catalog.importers run --source X --snapshot DIR`. A run from the same snapshot is a no-op (same sha256 gives the same rows). `import_runs` records the provenance.
- **openFDA NDC** (`openfda_ndc.py`, CC0):
  - from bulk `drug-ndc` JSON: product → Product (brand or generic name, labeler, market `us`); `packaging[]` → Package (count parsed best-effort from the description) + GTIN;
  - `active_ingredients` + `dosage_form` → Composition, using the RxNorm SCD from `openfda.rxcui` when present, otherwise a source-local composition (`source_key` = the source-native key, `identity_key` separate). **The RxNorm link is made only if the SCD row exists**; with RxNorm imported first the order is deterministic, and a later RxNorm import re-links (test);
  - filters: finished products, Rx and OTC.
  - **NDC→GTIN:** 10-digit package NDC (hyphens removed, configuration as printed), GTIN-12 = `3` + NDC10 + check digit, GTIN-14 = `00` + GTIN-12. Unit tests cover it, with a note about the FDA's possible 12-digit NDC format (risk).
- **RxNorm Prescribable** (`rxnorm.py`): RRF files (`RXNCONSO`, `RXNREL`, `RXNSAT`).
  - IN/PIN → Substance; SCD + SCDC components → Composition (strengths from `RXN_BOSS_*` / `RXN_AVAILABLE_STRENGTH`); DF → form.
  - No products: US products come from openFDA. Attribution to NLM is required.
- **RU sources** (milestone 4.4b, D1), per `docs/research/ru-sources.md`:
  - **ЕСКЛП** (`esklp.py`, flag `CATALOG_IMPORTER_ESKLP_ENABLED=false`): the xlsx "whole catalog" file or the XML/ZIP per the official ЕСКЛП passport schema. СМНН (INN + form + strength) → Substance + Composition (`complete = true` when strength and form are structured); КЛП (`klp.UUID`, `trade_name`, packs, `owner`, `manufacturer` with country, `num_reg`, `barcode`) → Product + Package + GTIN. `klp.UUID` and `smnn.UUID` are the `source_key`s; the file version and date go to `import_runs`. `barcode` (8–14 digits) is normalized (ADR 0013); restricted or invalid values are skipped with a counted warning, and an empty barcode just means no GTIN. The importer raises `ImporterDisabled` while the flag is false;
  - **Росздравнадзор opendata** (`ru_roszdravnadzor.py`, explicit open license): CSV/XML of rejected or withdrawn series → `recall_flags` (registration number, series), joined to ЕСКЛП products through `products.registration_number`; the card lists recalled series as a neutral note for manual comparison;
  - **ГРЛС** (`grls_manual.py`, `CATALOG_IMPORTER_GRLS_ENABLED=false`): parses the Excel export that the owner downloads by hand once a month and passes with `--snapshot`; no network `fetch`, no scraping; loader option `withdraw_missing=False`. It creates **no products**: it attaches EAN to existing ЕСКЛП packages by `num_reg` (a documented exception to "no cross-source linking") and updates registration status;
  - **Wikidata** (optional, CC0): INN ↔ ATC and RU/EN synonyms for `substances.name_ru` / `name_en`; never creates products;
  - names map to RxNorm/UNII substances only where the source carries an English INN or a UNII/ATC code; otherwise source-local substances (no cross-market merge);
  - parsers are written against the published schemas on synthetic, format-faithful fixtures; each source's license, attribution text and terms go into `catalog/LICENSES.md` and ADR 0012 §4.
- **EMA** (`ema.py`, second): the EPAR medicines report.
  - Product (brand, MAH, market `eu`) + substances. Compositions are `complete = false` because strength and form are not structured in that file. They feed overlap hints, never "same composition".
  - No GTINs: EU packages come only from consensus.
  - The dependency (`openpyxl`) is pinned with its license checked.
- **ЕСКЛП** in 4.3 is the protocol skeleton only (`esklp.py` raising `ImporterDisabled`); the real parser lands in 4.4b.
- **Fixtures:** synthetic but format-faithful (invented rxcuis, NDCs with valid check digits, names like "Testamol 500" / "Тестамол 500"), under `catalog/tests/fixtures/`. A smoke import of real snapshots is a manual checklist item.
- **Scheduling:** CLI only in Phase 4, run by the owner per deployment. An ARQ cron is a follow-up.

## Search design

- `POST /v1/search {q, market?, lang, kind?: product|substance, limit ≤ 20}`:
  - `q` is 2–100 chars after trimming. If `q` is 8/12/13/14 digits after removing spaces, the GTIN path runs (normalize, exact lookup).
  - Otherwise: `norm` with unaccent, ё→е, lower-case; `tsv @@ to_tsquery('simple', …:*)` (prefix on the last token) **or** `norm %> q` (pg_trgm `word_similarity`, threshold in settings) for typos.
- **Score** = ts_rank + similarity (typos); the source-authority term is deferred until a source can duplicate another (ADR 0012 section 5). Ordering: `ORDER BY withdrawn ASC, own_market DESC, score DESC, id` (withdrawn rows last for every result type; own market is a hard sort key; ties by `id` keep results deterministic).
- **D6:** own-market results first; foreign-market products follow and every result carries `country`, which the app shows as a label.
- Languages: the `simple` configuration (brand and INN names do not stem well). RU names come from the RU open sources (4.4b) and later ЕСКЛП, EN from RxNorm/openFDA/EMA. **No transliteration or cross-market synonyms** (no cross-market matching).
- Limits: `SET LOCAL statement_timeout` (300 ms), server-capped `limit`, body ≤ 4 KiB, per-IP and per-install rate limits (fail-open like the backend), no CORS.
- **No popularity ranking**: it would need usage tracking.
- Other endpoints:
  - `POST /v1/gtins/lookup {gtin}` → `{status: found|unknown|restricted|disputed, product, package, composition}`;
  - `POST /v1/products/get {id}` → one card with composition, substances and packages, for the cache (no batch: privacy B3);
  - `GET /v1/sources` → attribution for the app;
  - `/healthz`, `/readyz`.

## Scanning design

- **Shared contract:** `docs/spec/gtin.md` (written in 4.2) + `spec/gtin-vectors/{schema,normalize,gs1}.json` (≥ 40 cases), checked for shape by `spec/validate_vectors.py`.
- **Normalize:**
  - strip spaces and hyphens (manual entry);
  - length ∈ {8,12,13,14}, else `invalid_length`; non-digits → `invalid_characters`; mod-10 → `invalid_check_digit`;
  - left-pad to 14;
  - classify `shareable | restricted` (**D3**): GS1 prefixes 020–029 and 200–299 (TZ; "Restricted Circulation Numbers within a geographic region"), plus **040–049** ("Restricted Circulation Numbers within a company"), **RCN-8** (GTIN-8 whose first digit is 0 or 2) and **indicator digit 9** of a GTIN-14 (variable measure trade items). Sources: the GS1 prefix list and GS1 UK (ADR 0013 §2). Exact rules are pinned by vectors in 4.2.
- **GS1 parse:**
  - strip symbology ids (`]d2`, `]C1`, `]Q3`, `]e0`) and a leading FNC1/GS (`\x1d`);
  - walk AIs: predefined fixed lengths (00, 01, 02, 11–17, 20, 31xx–36xx, 41x) and variable ones ended by GS (10, 21, 22, 240, 241, 30, 37, 710–715, 90–99);
  - AI 17 → expiry (DD=00 means end of month), parsed, validated and **not stored** (D7);
  - **10 and 21 are consumed and discarded.** The result type has no field for them, so they cannot leak;
  - unknown AI after a valid 01 → GTIN with `partial: true`; no 01 → `unsupported_format` (QR URLs, securPharm PPN `[)>`, GS1 Digital Link: future).
- **Честный знак** (pharma): `01`+GTIN14, `21`+serial(13)+GS, `91`+key(4)+GS, `92`+crypto(44); 85 characters (ADR 0013 §3, verified against markirovka.ru). Vectors cover it with and without GS separators: the GTIN is still found because 01 is first and fixed-length.
- **Implementations:** reference `catalog/catalog/domain/{gtin,gs1}.py` (all vectors); `backend/app/domain/gtin.py` (normalize/shareable only, normalize vectors); `packages/pillpal_core/lib/src/catalog/{gtin,gs1}.dart` (all vectors).
- **App:**
  - `ScanSheet` (camera, formats EAN-8/EAN-13/UPC-A/DataMatrix only);
  - the camera permission is requested only on first scan, with a rationale; a denial leads to manual entry;
  - `ManualGtinEntry` (digits keyboard, live check-digit validation);
  - after a decode: core parse/normalize → (1) a **local match**: a medication in the current profile with the same `gtin` → "this is «X»" (works offline); (2) if shareable and online → lookup; (3) restricted or offline → no lookup; the GTIN may still be saved privately;
  - flashlight, no image capture or storage.

## Consensus

- **Backend job** `push_gtin_confirmations` (ARQ cron, `CATALOG_CONTRIBUTION_INTERVAL_SECONDS` = 3600; off unless `CATALOG_CONTRIBUTIONS_ENABLED`; strict environments refuse `true` until the Phase 5 consent records exist):
  - one SQL aggregate over live medications with `gtin_link_shared`, a shareable GTIN (`app/domain/gtin.py` filter) and a product, counting **distinct profile owners** whose accounts are verified, not pending and ≥ `CATALOG_CONTRIBUTION_MIN_ACCOUNT_AGE_DAYS` (7, D8) old;
  - sends `PUT /internal/v1/regions/{region}/gtin-confirmations` in pages `{generation, page, complete, items:[{gtin, product_id, count}]}` — nothing else leaves the regional backend (D2). Only items with `count ≥ CATALOG_CONTRIBUTION_MIN_REPORTED_COUNT` (2) are sent, so a count of one person never leaves; `decide()` is unchanged;
  - logs counts and status only.
- **Catalog ingest:**
  - the token is bound to its region (`CATALOG_INGEST_TOKENS` = `region:sha256` list, the name is the region `ru|eu`, two tokens per region for rotation) and the path region must match;
  - unknown or withdrawn `product_id`s are dropped and counted, never failing the page; a generation lower than the last committed one is rejected;
  - pages are staged by generation, and the region's candidates are swapped atomically on `complete`. Replays are idempotent;
  - affected GTINs are re-decided under an advisory lock.
- **`decide(official, counts, settings)`** (pure, `catalog/catalog/domain/consensus.py`, ~100% covered):
  - top product c1, runner-up c2 (summed over regions in a global deployment);
  - **fixed order, pinned by a table test:** `locked` → official (`disputed` only if a competitor reaches N; two young accounts cannot hide an official GTIN) → already `promoted` (sticky, same rule) → c2 ≥ `CATALOG_CONSENSUS_DISPUTE_MIN` (2, D8) → c1 ≥ `CATALOG_CONSENSUS_MIN_CONFIRMATIONS` (N = 3, D8) → `pending`;
  - promotion creates a `consensus` package with id `uuid5(NS, "consensus:package:<gtin14>:<product_id>")` (ADR 0012 §2) and a `gtins` row with `origin = consensus`.
  - Official rows are never auto-overridden. Promotion is sticky; admin can reject or lock. Disputed GTINs answer `disputed` with no product.
- **Admin:**
  - `GET /admin/v1/disputes`, `POST /admin/v1/gtins/{gtin}:resolve {action: promote|reject|lock, product_id?}`, `GET /admin/v1/import-runs`;
  - bearer tokens from `CATALOG_ADMIN_TOKENS` (`name:sha256`, two per role for rotation, constant-time compare), served by a **separate ASGI app on a private listener** (a test asserts the public app answers 404 for `/admin` and `/internal`), rate-limited, every action in `admin_audit`;
  - CLI `python -m catalog.admin disputes list|resolve` against the database (run inside the container).

## App changes

- **Data (4.9):**
  - drift v7: medication columns for the six fields (`manualIngredients` as JSON text); table `catalog_cache` (`kind`, `id`, `json`, `fetched_at`); `wipeAccountData` and scope eviction clear it, because the cache reveals medications;
  - `payloads.dart` / `server_rows.dart` send and parse the fields, always sending an explicit value, except `gtin_link_shared`, which is sent only for full-access scopes (arch B2);
  - `data/catalog/{catalog_api,catalog_dto,catalog_cache_repository,catalog_install_id}.dart`; `data/config.dart` reads `PILLPAL_CATALOG_URLS` (`ru=…,eu=…`). Without it all catalog UI is hidden, which CI builds rely on;
  - cache refresh: one card when it is opened, TTL 30 days; no background batch; entries no longer referenced are evicted.
- **Core (4.9):** `packages/pillpal_core/lib/src/catalog/composition_match.dart` → `sameComposition(candidate, meds)` and `substanceOverlap(candidate, meds)`. Same profile only, complete compositions only for "same", catalog substance ids (including `manual_ingredients[].substance_id`) for overlap.
- **Screens (4.10, 4.11):**
  - **Medication form:** "Найти в справочнике" autocomplete on the name field (debounced 300 ms, ≥ 2 chars, online only; offline says "поиск доступен онлайн"). Own-market results first, foreign ones after them with a country label (D6).
    - Choosing a product sets the references and **fills empty free-text fields only**; for each already filled field the form shows an explicit "заменить" offer and never overwrites silently (D5).
    - "Отвязать" clears the references and keeps the text.
    - "Состав вручную" (private; substance pick from catalog substances or free name).
  - **Scan button** on the Medications screen FAB and in the form → `ScanSheet` → found / unknown ("выберите продукт" search, then save with `gtin` + product; checkbox "Анонимно помочь другим распознавать эту упаковку", **default off, shown at link time only** (D2) and only when `/v1/me/features.catalog_contributions_enabled`) / restricted ("код магазина — не передаём в общий справочник"; the GTIN stays on the medication) / unsupported (manual entry).
  - **"Link package to existing medication" prompt (D4)** when `sameComposition` is not empty: "Это тот же состав, что «X». Привязать упаковку к нему?" → replaces X's `catalog_package_id`, `catalog_product_id` and `gtin` (and `catalog_composition_id` if it was empty) and keeps X's name, free text, schedules, stock and history; no new medication is created | "Создать отдельно".
  - **Overlap hint:** a neutral `InfoNote` "Оба содержат: {substances}" / "Both contain: …". Info icon, no warning colour, dismissible, never blocking, no medical wording.
  - **Product card** in medication detail: brand, manufacturer, country, form, ingredients and strengths, package count, source with attribution, "данные справочника могут быть неполными", withdrawn label. Read from the cache offline.
  - **Catalog sources screen** (Settings → About): attribution from `GET /v1/sources`.
- **Relatives:** `shared` medications expose the references (KEEP for projected), so the relative's app shows the product card. `anonymous` drops them, `hidden` is invisible. No catalog UI for viewers beyond the card.
- **Platform:** Android `CAMERA` permission with `uses-feature required=false`; iOS `NSCameraUsageDescription` (EN + RU `InfoPlist.strings`). No ads, no analytics events.

## Sync and protocol changes

- **Only** new optional fields on medication in `MedicationFields`, `MedicationUpdate`, `MedicationData` and `MedicationOut`: `catalog_product_id`, `catalog_package_id`, `catalog_composition_id` (UUID), `gtin` (14 digits), `gtin_link_shared` (StrictBool), `manual_ingredients` (≤ 10 items).
- **Keep-on-absent in push** via `model_fields_set`: an older APK's full-state upsert leaves stored values alone, and an explicit `null` clears. A same-state check compares only the fields that are present.
- **Privacy classification** (`domain/privacy.py`): the five content fields → `FULL_ONLY` (dropped from redacted); `gtin_link_shared` and the consent columns → `NEVER_PROJECTED` (the owner's consent is not relatives' business). The field-classification test forces this. The relative PDF uses `project_medication` (references dropped for `anonymous`, `hidden` absent).
- **Write rule** (`domain/write_access.py`): an editor upsert that **changes** `gtin_link_shared` → `forbidden_field`. Only full-access roles consent to contribution. Absent means unchanged, so editors' normal pushes pass. A change of `gtin` or `catalog_product_id` by anyone resets the consent (see Data model).
- Tombstones and account erasure erase the new fields, including the consent columns. `MedicationRedacted` is unchanged. `spec/openapi.json` is refreshed.
- No change to journal, scopes, cursors, schedule rule `v`, schedule or dose-state vectors.
- New backend surface: `/v1/me/features` gains `catalog_contributions_enabled`. The internal client calls the catalog; no new public endpoints.

---

## Milestones

| # | Milestone | Scope | Done when | PR | Status |
|---|---|---|---|---|---|
| 4.0 | Docs and contracts | This plan, ADRs 0011–0015, RU sources research, owner decisions D1–D8 recorded, Phase 5 appendix | Merged with owner sign-off | #33 | DONE |
| 4.1 | Catalog skeleton | `catalog/` uv project, settings, health/ready, logging, errors, rate limit, DB + Alembic baseline, Docker, `catalog.yml` | `catalog.yml` green; image builds | #25 | DONE |
| 4.2 | GTIN/GS1 contract | Spec, vectors, catalog Python, backend subset, Dart core | All three suites run all vectors; validator green | #34 | DONE |
| 4.3 | Catalog data model + importer framework | Tables, constraints, loader, `import_runs`, CLI, synthetic fixture importer, ЕСКЛП stub | Loader idempotency and withdrawal suites green | #36 | DONE |
| 4.4 | openFDA NDC + RxNorm importers | Parsers, NDC→GTIN, linking, licensing notes | Fixture imports reproduce expected rows | #40 | DONE |
| 4.4b | RU sources importers (D1) | ЕСКЛП importer behind `CATALOG_IMPORTER_ESKLP_ENABLED=false`; Росздравнадзор recall flags; manual ГРЛС Excel path; optional Wikidata INN enrichment; `name_ru`, RU market, GTINs from `barcode`, attribution | Fixture imports green; licensing table updated; ЕСКЛП refuses to run while the flag is off | #42 | DONE |
| 4.5 | Search and lookup API | Search, GTIN lookup, single-card get, sources, limits, privacy logging | Search and ranking suite green; p95 target on a generated dataset | #39 | DONE |
| 4.6 | Backend medication references | 0014/0015, schemas, keep-on-absent, projection, write rule, tombstones, inventory | Sync, privacy and editor suites green; OpenAPI refreshed | #37 | DONE |
| 4.7 | Consensus | Backend aggregator job + client; catalog ingest, `decide`, admin endpoints, CLI, audit | Consensus suite green end-to-end with fake transport | #41 | DONE |
| 4.8 | EMA importer | EMA parser, incomplete compositions, attribution | Fixture import green | #43 | in review |
| 4.9 | App data layer + core matching | drift v7, DTOs, catalog API/cache, `composition_match` | Unit tests green in CI | | planned |
| 4.10 | App catalog UI | Search in form, product card, link prompt, overlap hint, manual composition, sources screen | Widget tests, APK/iOS builds green | | planned |
| 4.11 | App scanner | `mobile_scanner`, scan sheet, manual entry, permissions | Widget tests with fake scanner; builds green | | planned |
| 4.12 | E2E, CI, infra, docs | Host e2e with a real catalog, emulator manual-entry phase, compose/staging/deploy | All workflows green | | planned |

### 4.0 Docs and contracts
- **Files:** `docs/phase4-plan.md`, `docs/adr/0011`–`0015`, `docs/research/ru-sources.md`. `docs/spec/gtin.md` is written by 4.2 (this plan and ADR 0013 only link to it); `CLAUDE.md` is updated by a separate PR.
- **Reviewers:** `architect`, `privacy-compliance-reviewer`, `security-reviewer`, `offline-sync-reviewer`. Findings go into the **Review log** section at the end of this file, as in Phase 3.
- **Done when:** merged with owner sign-off on D1–D8.

### 4.1 Catalog skeleton
- **Files:**
  - `catalog/{pyproject.toml,uv.lock,Dockerfile,alembic.ini,README.md}`;
  - `catalog/catalog/{main.py,config.py,observability.py,errors.py,ratelimit.py,db/session.py,api/health.py}`;
  - `catalog/alembic/versions/c0001_baseline.py` (extensions);
  - `catalog/tests/conftest.py` (real PG `pillpal_catalog_test`, Redis DB 1);
  - `.github/workflows/catalog.yml` (ruff, format, mypy strict, pytest ≥ 85% coverage, image build; push to GHCR only under `PUBLISH_IMAGES`);
  - `infra/docker-compose.yml` (service `catalog`, database `pillpal_catalog`), `infra/.env.example`.
- **Tests first:**
  - `/healthz` and `/readyz`;
  - access log carries the route template only, no query string, no body, no client IP;
  - error envelope;
  - settings refuse a missing database URL, and refuse admin or ingest token digests that are not 64-hex sha256 in strict environments (the catalog receives digests; the tokens themselves must be ≥ 32 chars when generated);
  - Redis rate-limit keys use an HMAC of IP and install id with a daily-rotated salt and TTL = window; no RDB/AOF on the catalog Redis; uvicorn `--no-access-log`; no IP or install id on 429 logs; load-balancer logs follow the same rule;
  - catalog Sentry is absent, or a regional DSN with `send_default_pii=False`, bodies off, and `q`/`gtin`/ids scrubbed; PostgreSQL `log_parameter_max_length_on_error=0`, `auto_explain` off, bound parameters only;
  - a schema-introspection test also forbids `install*` columns and free-text jsonb in ingest tables;
  - **an import-boundary test**: no module imports `app.*`, and no table has an `email`, `user_id` or `device` column (schema introspection);
  - container runs as non-root.
- **Reviewers:** `security-reviewer`, `code-reviewer`. Risk: low.

### 4.2 GTIN/GS1 contract (spec, vectors, Python, Dart in one PR)
- **Files:**
  - `docs/spec/gtin.md` (finalized); `spec/gtin-vectors/{README.md,schema.json,normalize.json,gs1.json}`; `spec/validate_vectors.py` (+ `spec/gtin_checks.py`, stdlib);
  - `catalog/catalog/domain/{gtin,gs1}.py` + `catalog/tests/domain/test_gtin_vectors.py`;
  - `backend/app/domain/gtin.py` + `backend/tests/domain/test_gtin_vectors.py`;
  - `packages/pillpal_core/lib/src/catalog/{gtin,gs1}.dart` (+ export) + `test/catalog/gtin_vectors_test.dart`.
- **Tests first (vectors):**
  - EAN-8, EAN-13, UPC-A, GTIN-14 valid; wrong check digit; wrong lengths; spaces/hyphens; non-digits;
  - prefixes 020, 029, 200, 299 restricted; 040, 049 restricted; RCN-8 (`0…`, `2…`) restricted; indicator 9 restricted (D3); 460 (RU), 300–379 and 50 shareable; NDC-derived GTIN; a GTIN-8 starting with 4 or 9 shareable;
  - GS1 with `]d2`, with leading GS, AI order 01-17-10-21, 21 before 01, 17 with day 00, 17 with an impossible date → `invalid_expiry` but GTIN kept;
  - ЧЗ with and without GS; 710 NHRN; unknown AI after 01 → partial; QR URL / PPN → unsupported;
  - **result never contains serial or lot** (schema forbids the keys).
- **Reviewers:** `schedule-engine-guardian` (vector/parity discipline), `privacy-compliance-reviewer` (serial/lot), `code-reviewer`. Risk: medium.

### 4.3 Catalog data model and importer framework
- **Migrations:** `c0002_catalog_core` (sources … gtins, `gtin_*` SQL functions), `c0003_search_entries`.
- **Files:** `catalog/catalog/db/models.py`, `catalog/catalog/importers/{base,loader,ids,cli,fixture,esklp}.py`, `catalog/catalog/domain/identity.py` (canonical composition key, UUIDv5 namespace).
- **Tests first:**
  - run twice on the same snapshot → identical rows and no new run effects;
  - a record missing in run 2 → `withdrawn_at` set, still resolvable by id;
  - restricted GTIN rejected by the DB CHECK even when inserted directly;
  - composition identity independent of ingredient order; same composition in two sources → two rows (no cross-market merge);
  - concurrent runs of one source → second refused;
  - ЕСКЛП stub refuses while the flag is off;
  - `search_entries` rebuilt atomically;
  - migration round-trip.
- **Reviewers:** `architect`, `code-reviewer`, `security-reviewer` (archive extraction: zip-slip, size caps). Risk: medium.

### 4.4 openFDA NDC and RxNorm importers
- **Files:** `catalog/catalog/importers/{openfda_ndc,rxnorm,ndc}.py`, fixtures `catalog/tests/fixtures/{openfda,rxnorm}/`, `catalog/LICENSES.md` (source terms, attribution strings).
- **Tests first:**
  - NDC 4-4-2/5-3-2/5-4-1 → GTIN-14 with a valid check digit;
  - product with `openfda.rxcui` → links to the SCD composition; without → source-local composition by UNII;
  - multi-ingredient strengths parsed; unparseable package count → null;
  - non-finished products skipped;
  - RxNorm SCD components → ingredients with strengths;
  - fetch verifies sha256 and size caps (downloads through `httpx.MockTransport`).
- **Reviewers:** `code-reviewer`, `security-reviewer`. Risk: medium (source format drift).

### 4.4b RU sources importers (D1)
- **Input:** `docs/research/ru-sources.md` (its verdicts are fixed by D1): ЕСКЛП is the only state source with trade name, INN, form, strength, manufacturer and barcode in one file but has no published license text; Росздравнадзор opendata has an explicit open license but no catalog; ГРЛС has no bulk dump (manual Excel export only); Честный знак / Национальный каталог / Vidal / РЛС are contract-only and rejected.
- **Files:** `catalog/catalog/importers/{esklp,ru_roszdravnadzor,grls_manual,wikidata}.py`, fixtures `catalog/tests/fixtures/{esklp,roszdravnadzor,grls}/` (synthetic, format-faithful, Cyrillic names), `catalog/LICENSES.md`, ADR 0012 §4 licensing table, no new revision for the tables: `recall_flags`, `products.registration_number`, `substance_names` and the `sources` seed all live in `c0002` (built in 4.3).
- **Rules:** `CATALOG_IMPORTER_ESKLP_ENABLED=false` and `CATALOG_IMPORTER_GRLS_ENABLED=false` by default, checked in `fetch` and `run`; no scraping of any page; ГРЛС only from a file passed by the operator; `fetch` honours size caps and sha256; GTINs only from ЕСКЛП `barcode` and the ГРЛС export, normalized and restricted-filtered; source-local substances when no INN mapping exists.
- **Tests first:**
  - **ЕСКЛП refuses to run while the flag is false**, and runs on the fixture when true; fixture → products with `market = 'ru'`, `name_ru`, `form_name_ru`, manufacturer and country;
  - СМНН with structured strength + form → `complete = true`, otherwise `false`; INN with a known UNII/RxNorm key → shared substance id, else source-local;
  - `barcode` of 8/12/13/14 digits → GTIN-14 package link; restricted or bad check digit skipped with a counted warning; empty barcode → package without GTIN;
  - Росздравнадзор fixture → `recall_flags` joined by registration number; the card note lists series neutrally;
  - ГРЛС Excel fixture (flag on) attaches EAN to ЕСКЛП packages by `num_reg`, creates no products, withdraws nothing, makes no network call; refuses while `CATALOG_IMPORTER_GRLS_ENABLED=false`;
  - Wikidata seed row exists; RU INN names land in `substance_names`;
  - re-import withdraws missing rows; `search_entries` get `lang = 'ru'` rows with ё→е normalization;
- **Owner checklist before enabling ЕСКЛП:** (1) download the file from `esklp.egisz.rosminzdrav.ru` and confirm it is available **without authentication**; (2) send a written request to Минздрав / ЦНИИОИЗ on the terms of use in a commercial app; (3) get answers to the Legal review items 1–2; (4) **smoke-import a real ЕСКЛП / ГРЛС / Росздравнадзор file** into a scratch database (the formats and header wording are written from descriptions and verified on synthetic fixtures only, the headers are guesses) and compare the counts with the portal; only then set the flag. Roszdravnadzor follows the ЕСКЛП flag (its flags attach to ЕСКЛП products). **Wikidata enrichment is a separate later task** (it needs a loader path that adds names to other sources' substances and rebuilds their search entries); the `wikidata` seed row exists in `c0002`.
- **Reviewers:** `architect` (source choice, licensing), `security-reviewer` (download and parsing limits), `privacy-compliance-reviewer` (public data only; manufacturer names that are individual entrepreneurs), `code-reviewer`. Risk: medium-high (license and format uncertainty).

### 4.5 Search and lookup API
- **Files:** `catalog/catalog/api/{search,gtins,products,sources}.py`, `catalog/catalog/services/{search,cards}.py`, `catalog/catalog/schemas/*.py` (`extra="forbid"`), `catalog/openapi.json` snapshot.
- **Tests first:**
  - brand prefix; INN; typo ("paracetmol"); ru with ё/е; market boost order (own market first, foreign after, each with `country`, D6); withdrawn last; deterministic ties;
  - GTIN path from digits; lookup statuses (found, unknown, restricted, disputed);
  - `GET /v1/sources` returns the attribution of every enabled source; single-card get (unknown id → 404); query length limits;
  - «ибупрофен» finds foreign products through `substance_names`; withdrawn rows sort last in every result type; statement timeout returns `503 catalog_timeout` without SQL;
  - rate limit per IP and per install → 429;
  - **log capture: no `q`, GTIN, product id or IP in any line**; no `Authorization` accepted or required;
  - CORS absent.
- **Reviewers:** `privacy-compliance-reviewer`, `security-reviewer`, `code-reviewer`. Risk: medium.

### 4.6 Backend: medication catalog references
- **Migrations:** `0014_medication_catalog_refs`, `0015_med_manual_ingredients`.
- **Files:**
  - `backend/app/db/models.py` (`MEDICATION_CONTENT`, CHECKs, index); `backend/app/schemas/entities.py` (fields, `ManualIngredient`, keep-on-absent for `MedicationData`);
  - `backend/app/services/sync.py` (`_upsert_medication` uses the fields that are present); `backend/app/services/entities.py`;
  - `backend/app/domain/privacy.py` (classification); `backend/app/domain/write_access.py` (`gtin_link_shared` change → `forbidden_field`);
  - `backend/app/observability.py` (`SENSITIVE_KEYS` += `gtin`, `catalog_product_id`, `catalog_package_id`, `catalog_composition_id`, `manual_ingredients`, `q`);
  - `backend/app/api/auth.py` (features flag); `backend/app/settings_catalog.py` (new; `config.py` is already over 400 lines);
  - `spec/openapi.json`.
- **Tests first:**
  - create/update/pull round-trip;
  - **an old-client push without the fields keeps them; an explicit null clears them**;
  - LWW unchanged; tombstone nulls the five reference fields, sets `gtin_link_shared = false` and clears the consent fields;
  - the consent reset is part of the same versioned update, so the next pull returns `gtin_link_shared = false` to the owner's other devices; the app's `gtin_link_consent_version` is validated against the supported set (unknown → 422) and stored with a server timestamp;
  - viewer of `shared` sees the references and not `gtin_link_shared`; `anonymous` redacted without references;
  - editor changing `gtin_link_shared` → `forbidden_field` with projected `current`; editor push without it → applied; **an editor re-link or any `gtin`/`catalog_product_id` change resets `gtin_link_shared` and the consent columns**; an app push for a non-full-access scope omits the flag; tombstone sets the flag false;
  - strict settings refuse `CATALOG_CONTRIBUTIONS_ENABLED=true` before consent records exist;
  - CHECK `gtin_link_shared` needs gtin + product; invalid GTIN shape → 422; `manual_ingredients` > 10 → 422;
  - REST PATCH partial; 401/404 foreign;
  - field-classification test; needle deletion test; migration round-trip 0014–0015.
- **Reviewers:** `offline-sync-reviewer`, `privacy-compliance-reviewer`, `security-reviewer`, `code-reviewer`. Risk: medium-high (sync payload compatibility). The PR body flags a migration and a sync payload change.

### 4.7 Consensus
- **Files:**
  - backend: `app/services/catalog_contributions.py` (aggregate query), `app/catalog_client.py` (httpx; https required in strict environments), `app/worker.py` (cron); `app/services/personal_data.py` (no new tables; documents that only aggregates leave);
  - catalog: `catalog/catalog/domain/consensus.py`, `catalog/catalog/api/{internal,admin}.py`, `catalog/catalog/services/{ingest,decisions}.py`, `catalog/catalog/admin/cli.py`, migration `c0005_consensus` (`c0004_search_support` of 4.5 already created `gtin_link_decisions`; this revision adds the remaining consensus tables).
- **Tests first:**
  - `decide()` table in the pinned order (locked, official, sticky promotion, dispute at 2, promote at N = 3, pending; two young accounts do not hide an official GTIN; D8); counts of one are never sent; unknown product ids dropped; lower generation rejected;
  - aggregator counts distinct owners, two managed profiles of one owner = 1, excludes unverified/pending/younger than 7 days/opted-out/restricted/tombstoned and counts below 2, **sends no ids other than GTIN and product**;
  - paged snapshot swap only on `complete`; replay idempotent; region/token mismatch → 403; erasure → next snapshot lowers counts;
  - admin token wrong → 401; every admin action audited; CLI resolve;
  - the public lookup reflects promotion and dispute.
- **Reviewers:** `privacy-compliance-reviewer`, `security-reviewer`, `architect`, `code-reviewer`. Risk: high (data contribution and new trust boundary).

### 4.8 EMA importer
- **Files:** `catalog/catalog/importers/ema.py`, `ema_fetch.py`, fixture xlsx (synthetic, built in tests: `tests/importers/ema_data.py`), `catalog/LICENSES.md`. Built with the stdlib `xlsx.py` reader; `openpyxl` was not added.
- **Tests first:** products with multiple substances → incomplete composition; MAH as manufacturer; re-import withdraws; never `complete = true`.
- **Reviewers:** `code-reviewer`, `security-reviewer` (xlsx parsing limits). Risk: low-medium.

### 4.9 App data layer and core matching
- **Files:**
  - `app/lib/src/data/db/{tables,database}.dart` (v7, `catalog_cache`, wipe/evict);
  - `data/repositories/{payloads,medications_repository}.dart`, `data/sync/server_rows.dart`;
  - `data/catalog/*`, `data/config.dart`;
  - `packages/pillpal_core/lib/src/catalog/composition_match.dart`.
- **Tests first:**
  - migration v6→v7; payload always carries the fields; pulled redacted row has none;
  - cache: wipe on sign-out/deletion and evicted with a scope; offline card from cache; refresh of a single card on open (TTL 30 days);
  - catalog requests carry no `Authorization` or backend device id, and use POST;
  - `composition_match`: same complete composition, incomplete never "same", overlap by substance ids, manual substance ids, different profiles ignored.
- **Reviewers:** `offline-sync-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`. Risk: medium.

### 4.10 App catalog UI
- **Files:** `app/lib/src/features/catalog/{catalog_search_field,catalog_search_sheet,product_card,link_package_prompt,overlap_hint,manual_ingredients_editor,catalog_sources_screen}.dart`; `features/medications/{medication_form,medication_edit_screen,medication_sections}.dart`; l10n RU/EN.
- **Tests first:**
  - offline shows the hint and no search;
  - selecting fills empty fields only; a filled field gets the "replace" offer and is unchanged until accepted (D5); unlink keeps text;
  - foreign-market results are rendered after own-market ones with the country label (D6);
  - any re-link (including the D4 prompt) sends `gtin_link_shared = false` unless the box was ticked again in that flow;
  - prompt shown for the same composition and **links the package to the existing medication** (references replaced, name/schedules/stock kept, no new row; D4); "создать отдельно" works;
  - overlap hint text neutral (golden strings RU/EN), never blocks save;
  - card from cache with attribution and withdrawn label;
  - redacted medication shows no card;
  - catalog UI hidden without `PILLPAL_CATALOG_URLS`;
  - largest text scale.
- **Reviewers:** `privacy-compliance-reviewer`, `code-reviewer`. Risk: medium.

### 4.11 App scanner
- **Dependencies:** `mobile_scanner` (exact pin, BSD-3; bundled ML Kit on Android — the plugin default; `useUnbundled` must stay unset).
- **Files:** `app/lib/src/features/catalog/{scan_sheet,scanner_adapter,manual_gtin_entry,scan_flow}.dart`; `AndroidManifest.xml`, `Info.plist`, `InfoPlist.strings`; `app-release.yml` / `.github/scripts/` check that no unbundled ML Kit or Play Services barcode dependency is merged.
- **Tests first** (fake `ScannerAdapter`):
  - EAN-13 found → product flow; ЧЗ DataMatrix → GTIN only;
  - **the serial is never stored, sent or logged** (fake HTTP asserts the request bodies); the expiry date is never persisted (D7);
  - local GTIN match offline; restricted → private save, no network; unsupported → manual entry; permission denied → manual entry;
  - opt-in checkbox only at link time, default off, only when the feature flag is on and the GTIN is shareable and unknown (D2);
  - check digit validation in manual entry;
  - manual step: capture device traffic once to confirm that ML Kit sends only datatransport telemetry; the RU flavor keeps `flutter_zxing` ready as the fallback.
- **Reviewers:** `privacy-compliance-reviewer`, `security-reviewer`, `code-reviewer`. Risk: medium.

### 4.12 E2E, CI, infra, docs
- **Deployment note (from the 4.7 reviews):** alert on a failing retraction (`catalog_push_failed` while contributions are disabled) and on `catalog_generation_stale`; a retraction that keeps failing leaves counts at the catalog until they expire after `CATALOG_INGEST_MAX_AGE_HOURS` (72 h).
- **Files:**
  - `app/test_e2e/catalog_test.dart` (real backend + real catalog loaded from the synthetic fixture: search → select → save → pull on a second device shows the references; unknown GTIN → link with opt-in → aggregator run → three accounts → lookup promoted);
  - `.github/workflows/app.yml` e2e job (start catalog, import fixture);
  - emulator phase `catalog` (manual GTIN entry path; the camera is not available);
  - `infra/staging/{docker-compose.yml,Caddyfile,.env.example}` (catalog host; no `log` directive, or a format without URI/IP; `/admin` and `/internal` not routed);
  - `deploy-staging.yml` (catalog image, `alembic upgrade head`);
  - `docs/staging.md` (import commands, attribution); `catalog/README.md`. `CLAUDE.md` is updated by separate PRs.
- **Reviewers:** `e2e-runner`, `security-reviewer`, `code-reviewer`, `doc-updater`. Risk: medium.

---

## Migrations and compatibility

| Revision | Milestone | Concern | Downgrade |
|---|---|---|---|
| `0014_medication_catalog_refs` (backend) | 4.6 | five nullable columns, one bool with default (metadata-only), CHECKs (NOT VALID + VALIDATE), partial index (`CONCURRENTLY`) | drop |
| `0015_med_manual_ingredients` (backend) | 4.6 | jsonb column + shape CHECK; the tombstone CHECK is extended to it here (`0014` covers the other reference and consent columns, it cannot name a column that does not exist yet) | drop |
| `c0001`–`c0005` (catalog, separate `alembic_version`; `c0002` also holds `recall_flags`, `substance_names`, `registration_number`; `c0004` = substance reverse index + `gtin_link_decisions`) | 4.1, 4.3, 4.5, 4.7 | catalog schema, source seeds, `recall_flags` | drop |

- No rewrite of `medications` or `dose_events`. Revision ids stay ≤ 32 chars.
- **Installed staging APKs:** keep-on-absent keeps their pushes harmless. They ignore unknown pulled fields; the 4.6 test asserts the current app's parser tolerates unknown keys.
- Schedule rule `v`, schedule and dose-state vectors unchanged. New vector set `gtin-vectors`.

## Privacy and region impact

- **Catalog:** public data only, enforced by the schema-introspection test and by the separate image. Search strings and GTINs are processed but never stored or logged. Requests are unlinkable to accounts (no auth, catalog-only install id, POST bodies, no IP logs). PostgreSQL parameter logging is off.
- **Backend:** new medical fields on `medications`. They are erased on tombstone and account erasure, projected (`FULL_ONLY` / `NEVER_PROJECTED`), added to `SENSITIVE_KEYS` and Sentry scrubbing, and never in push payloads. They will be covered by the Phase 5 export through the existing inventory.
- **Contribution (D2):** an opt-in per link, made by a full-access role at link time, default off. Only aggregate counts `{gtin, product_id, count}` leave the regional backend, to the catalog **of the same region** by default. In a global deployment, aggregates (not personal data) cross regions.
- **Serial and lot** (Честный знак, FMD) never leave the parser. Expiry is parsed and not stored (D7).
- **Third parties:** Google ML Kit metrics (Android, both regions). Apple Vision is on-device. No new SDK otherwise. Ads never on catalog or scan screens.
- **Regions:** no cross-region links. The regional catalog is reached from the region's app only (`PILLPAL_CATALOG_URLS` per region).

## Legal review required before launch

Not code defects; to be confirmed by counsel before production (Phase 5 legal documents):
1. **ЕСКЛП/ГРЛС:** commercial reuse of the ЕСКЛП file (no license text found) and of ГРЛС exports (the Минздрав site terms of 2014 forbid commercial use). Gates only the ЕСКЛП importer flag and the manual ГРЛС path, not Phase 4 (D1). The lawyer questions Q1–Q7 of `docs/research/ru-sources.md` ("Вопросы юристу") are part of this item: official documents (art. 1259(6) GK) vs the database maker's right (art. 1334); applicability of the 2016 model open-data terms to the ЕСКЛП file; applicability of the 2014 site terms to other domains; lawfulness of automated or manual Excel collection (art. 272 UK, art. 13.11 KoAP); how to request use from Минздрав and whether a ЦНИИОИЗ contract is needed; attribution and error disclaimer; whether user-supplied EANs and names in a shared catalog are personal data and whether RU↔EU transfer is allowed.
2. **Росздравнадзор and Wikidata:** confirm the attribution wording of the open-data terms; confirm that manufacturer or MAH names are not personal data in the sense of 152-FZ when the holder is an individual entrepreneur.
3. **RxNorm** (NLM terms: attribution, disclaimer; confirm Prescribable Content needs no UMLS license); **openFDA** (CC0, disclaimer "not for clinical decisions"); **EMA** (reuse with acknowledgement per the EMA legal notice; confirm for the specific dataset).
4. **Google ML Kit** usage metrics (ADR 0013 §6): third-party disclosure in the privacy policy, and RKN cross-border notification for RU; whether the unlinkable metrics count as personal data at all.
5. **Contribution consent wording (D2)** (also: is «Анонимно» accurate when the backend processes identified data to count; guardian consent for a managed adult; sticky promoted links vs erasure) and legal basis (GDPR art. 9 explicit consent; 152-FZ) for using medication data to compute anonymous aggregates; whether a count is anonymous data (and the residual Sybil oracle of ADR 0014: two accounts of the minimum age plus the public found/disputed answer reveal that one more person confirmed the pair; cross-border transfer of counts in a global deployment); whether withdrawing the opt-in needs a confirmation.
6. **Medical-device classification risk** (EU MDR / Roszdravnadzor) of the overlap hint (no analog list, D9), the "same composition" prompt and product cards: confirm informational wording without recommendations.
7. **Catalog accuracy disclaimer** in the app and store listings; purchase retention vs deletion; promo and ad-removal terms; liability for wrong consensus links (D8 thresholds are a product choice, not a legal guarantee).
8. **Scanning a Честный знак code**: confirm that reading a code on the user's own pack and discarding the serial needs no agreement with ЦРПТ (the app never queries the ЧЗ API).

## Reviewers to run (agents)
- `architect` (4.0, 4.3, 4.4b, 4.7)
- `schedule-engine-guardian` (4.2, vector parity)
- `offline-sync-reviewer` (4.0, 4.6, 4.9)
- `privacy-compliance-reviewer` (4.0, 4.2, 4.4b, 4.5–4.7, 4.9–4.11)
- `security-reviewer` (4.0, 4.1, 4.3–4.8, 4.11, 4.12)
- `e2e-runner` (4.12)
- `code-reviewer` and `doc-updater` on every PR
- `notifications-specialist`: not needed (no reminder change)

## Done when (phase)
- [ ] `/verify` green: backend and core, plus the catalog suite (ruff, format, mypy strict, pytest ≥ 85% on real PG/Redis); Dart format, analyze and test in CI.
- [ ] `python spec/validate_vectors.py` green; schedule, dose-state and **gtin** vectors pass in every implementation.
- [ ] `backend.yml`, `catalog.yml`, `core.yml`, `app.yml` (with catalog e2e) and `app-emulator.yml` green; `app-release.yml` and `app-ios.yml` green without credentials.
- [ ] `alembic upgrade head` / `downgrade -1` round-trip for 0014–0015 and c0001–c0005; `spec/openapi.json` and `catalog/openapi.json` refreshed.
- [ ] Manual checklist (not blocking merge): real snapshot imports (openFDA, RxNorm, RU open source(s), EMA), real packs scanned (EAN-13, UPC-A, ЧЗ DataMatrix, an EU FMD pack), a non-GMS Android device, iOS camera, legal items answered.

## Out of scope / follow-ups
- Cross-market product matching and merging; transliteration; popularity ranking; import scheduling (ARQ cron); storing expiry dates (D7); GS1 Digital Link and PPN parsing; OCR (TZ §6); Phase 5 work (appendix).

---

## Owner decisions (2026-10-21; D1 refined 2026-10-22)

| # | Topic | Decision | Where it lands |
|---|---|---|---|
| D1 | RU sources without a ЕСКЛП license text | **Do not block Phase 4.** ЕСКЛП is the only state source with brand + INN + form + strength + manufacturer + barcode in one file but has no published license text, so milestone **4.4b** builds the ЕСКЛП importer (xlsx/XML per the official passport: КЛП + СМНН incl. `barcode`) behind `CATALOG_IMPORTER_ESKLP_ENABLED=false`, plus the Росздравнадзор opendata importer (explicit open license) for recalled-series flags. ГРЛС only through a documented manual monthly Excel export (no scraping). Честный знак / Национальный каталог / Vidal / РЛС rejected (contract only). Wikidata optional for INN enrichment. Owner checklist: verify that the ЕСКЛП file downloads without authentication; send a written request to Минздрав / ЦНИИОИЗ. Lawyer questions of `docs/research/ru-sources.md` go to the Legal review list. | ADR 0012 §4 and licensing table; 4.3, 4.4b, Legal review 1–2 |
| D2 | Contribution consent and catalog deployment | **Per-link opt-in checkbox at link time, default off.** Only aggregates `{gtin, product_id, count}` leave the regional backend. **One catalog per region** by default; a global deployment stays possible with the same image. | ADR 0011 §3, ADR 0014 §2–§3, ADR 0015 §4; 4.6, 4.7, 4.11 |
| D3 | Restricted numbers beyond TZ's 02/20–29 | **Also exclude 040–049, RCN-8 (GTIN-8 starting with 0 or 2) and GTIN-14 indicator digit 9** (variable measure). Verified against the GS1 prefix list (`gs1.org/prefixes`) and GS1 UK; see ADR 0013 §2. Restricted GTINs may still be saved privately on the medication. | ADR 0013 §2, `docs/spec/gtin.md` §3; 4.2, 4.3 (DB CHECK), 4.7 |
| D4 | "Link package to existing medication" effect | **Replace** the existing medication's package / product / GTIN references; **keep** its name, free text, schedules, stock and history. "Create separately" is always offered. | ADR 0015 §6; 4.9, 4.10 |
| D5 | Selecting a product vs typed text | **Fill empty free-text fields only.** Each already filled field gets an explicit "replace" offer; nothing is overwritten silently. | ADR 0015 §5; 4.10 |
| D6 | Foreign-market results | **Shown after own-market results, labelled with the country.** | ADR 0012 §5, ADR 0015 §5; 4.5, 4.10 |
| D7 | Expiry date (AI 17) | **Parsed, validated, not stored** (no field in the result that persists; possible future feature). | ADR 0013 §4, `docs/spec/gtin.md` §5; 4.2, 4.11 |
| D8 | Thresholds | **N = 3** matching confirmations to promote, **dispute at 2** confirmations for a competing product, **account age ≥ 7 days** to count. All three are settings. | ADR 0014 §4; 4.7 |
| D9 | Analogs | **No analog list and no analog hint.** Only the substance-overlap hint and the D4 prompt remain. | ADR 0015 §6; 4.9, 4.10 |

## Review log (2026-11-09)

Reviewers: `privacy-compliance-reviewer` (B1–B3, S1–S6, N1–N5) and `architect` (B1–B5, S1–S10, N1–N7). Applied as follows; no finding was rejected.

- **Consent (privacy B1/B2, arch B3):** consent follows the `(gtin, product)` pair: the server resets `gtin_link_shared` and clears the new server-set `gtin_link_consent_version` / `gtin_link_consented_at` (NEVER_PROJECTED, erased) on any change of `gtin` or `catalog_product_id`, unless a full-access upsert sets it true. App resets on re-link and re-offers the checkbox. Strict environments refuse `CATALOG_CONTRIBUTIONS_ENABLED=true` before Phase 5 consent records. Data model, sync section, 4.6 tests, ADR 0014 §2, ADR 0015 §4.
- **Cache refresh (privacy B3):** no weekly batch; one card on open, TTL 30 days; `/v1/products/batch` replaced by `/v1/products/get`. Plan, ADR 0015 §2–§3.
- **Tombstone (arch B1, N5):** `gtin_link_shared` stays out of `MEDICATION_CONTENT`; CHECK `deleted_at IS NULL OR NOT gtin_link_shared`; tombstoning sets it false; the `tombstone_erased` change moves into `0014`.
- **Payload (arch B2):** `gtin_link_shared` is sent only for full-access scopes.
- **Migration id (arch B4):** `0015_med_manual_ingredients` (≤ 32 chars).
- **decide() order (arch B5):** locked → official → sticky promoted → dispute at 2 → promote at N → pending; table test; ADR 0014 §4.
- **Privacy S1:** only counts ≥ 2 are sent (`CATALOG_CONTRIBUTION_MIN_REPORTED_COUNT`), catalog CHECK `confirmations ≥ 2`. **S2/S3:** HMAC rate-limit keys with daily salt, no RDB/AOF, `--no-access-log`, Sentry and PostgreSQL logging rules (4.1 tests, ADR 0011 §2). **S4:** admin/internal on a separate private ASGI app, two tokens per role/region (ADR 0011 §4, ADR 0014 §5). **S5/S6:** Phase 5 appendix (inventory, export download, promo lockout and breaker, separate HMAC key, grant e-mail via stdin), labelled non-binding.
- **Privacy N1–N5:** install id rotates every 30 days; relative PDF via `project_medication`; analytics forbids catalog/scan events; introspection test forbids `install*` and free-text jsonb; 4.11 traffic capture and `flutter_zxing` fallback. Legal review list extended (items 5–7).
- **Architect S1/S2:** `gtins` keyed by `(gtin, source)` with precedence; one consensus package id `uuid5(NS, "consensus:package:<gtin14>:<product_id>")` (ADR 0012, 0014, plan). **S3/N6:** ingest drops unknown product ids, rejects a lower generation. **S4:** `products.registration_number` and `recall_flags` defined; recall flags need ЕСКЛП. **S5:** `CATALOG_IMPORTER_GRLS_ENABLED=false`, `withdraw_missing=False`, EAN attached to ЕСКЛП packages by `num_reg`. **S6:** `substance_names`, `wikidata` seeded, mandatory RU INN names. **S7:** single ordering rule. **S8/S9:** RxNorm link only if the SCD row exists; source-native `source_key`. **S10:** `GET /v1/sources` test moved to 4.5.
- **Architect N1–N4, N7:** token wording reworded (digests); ADR 0011 CLAUDE.md line aligned with "separate PR"; `ru-sources.md` recommendation superseded note; restricted-GTIN copy «не передаём в общий справочник»; Phase 5 appendix kept as non-binding.
- **D9 (owner):** no analog list or analog hint; removed from ADR 0015 §6 and the plan.
- **Status note:** ADRs stay `accepted` (owner decisions D1–D9 are given); 4.2 runs before 4.0 merges as an accepted exception.
- **Re-check items:** ADR 0014 §4 table now has `locked` first and an "already promoted" row (same order as the plan); 4.6 tombstone wording fixed; new 4.6 test that the consent reset reaches other devices in the next pull; new 4.10/4.11 test that every re-link sends `gtin_link_shared=false` unless re-ticked; `gtin_link_consent_version` is sent by the app and validated by the server (unknown → 422).


---

## Appendix — Phase 5 functional slice

**Non-binding; planned in a separate Phase 5 functional plan.** Everything here is **buildable now**, behind flags that default to off, with fakes in tests (no external accounts needed). It is a proposal for the owner to schedule; Phase 5 starts only when the owner asks. Each item keeps the existing rules: backend on real PostgreSQL, no medical data in logs or analytics, regional deployments only.

### Buildable now

- **Consent records.** A `consents` table (`kind`: `health_data`, `terms`, `privacy`, `catalog_contribution`; `version`, `accepted_at`, `withdrawn_at`), included in deletion and export. Registration requires the current health-data version; withdrawing it goes through the account-deletion path (ADR 0010). The `catalog_contribution` kind records the version of the checkbox text of ADR 0015 §4. Texts are placeholders until legal.
- **Data export.** `POST /v1/me/export` -> ARQ job -> JSON archive built from the `TABLE_CLASSIFICATION` owner columns (including the Phase 4 medication fields), single-use short-TTL download bound to the authenticated session (never in a URL query), archive encrypted in-region, purged at 24 h, never e-mailed, rate-limited. Fully testable.
- **OAuth framework.** An `auth_identities` table; an `IdentityProvider` protocol; Apple and Google ID-token verification (JWKS, `iss`/`aud`/`nonce`); VK ID and Yandex ID code exchange; the availability matrix **provider x region x platform** from TZ §1 (for example RU: VK ID and Yandex ID on Android and iOS, Apple on iOS; EU: Apple and Google); account linking rules (a verified e-mail never auto-merges two accounts without a confirmation). Fakes: a local JWKS and `httpx.MockTransport`. Every provider stays disabled without its client id.
- **Payments backend.** A `purchases` table, a verifier protocol, `GET /v1/me/entitlements`, soft limits wired to entitlements, `FEATURE_PAYMENTS=false`. StoreKit 2 JWS verification is testable with a test certificate chain; RuStore Pay and Play Billing verifiers are stubs.
- **Ads-free entitlement with promo codes (owner decision 2026-10-22).**
  - Entitlement `ads_removed` is **per account**. It covers that account's managed profiles (the app shows no ads for the account while it is signed in). It does **not** extend to relatives or co-guardians, who have their own accounts and their own entitlement.
  - Sources: `purchase` (store payment, behind `FEATURE_PAYMENTS`), `promo` (redeemed code), `admin_grant` (direct grant). Table `entitlements (account_id, kind, source, granted_at, expires_at null, revoked_at)`; the effective state is computed from non-revoked, non-expired rows. Independent of store payments: a promo or grant works with `FEATURE_PAYMENTS=false`.
  - **Promo codes** are generated by an admin CLI (`python -m app.admin promo create --label … --max-activations N --expires …`), at least 16 characters from an unambiguous alphabet, shown once and **stored hashed** (sha256 with a server secret, constant-time compare), with expiry, max activations and a free label (campaign name, no personal data). Redemption table `promo_redemptions (code_id, account_id, redeemed_at)` with UNIQUE `(code_id, account_id)`; redeeming twice is idempotent, exceeding max activations or expiry returns a stable error code.
  - **Redeem** in Settings: `POST /v1/me/promo/redeem {code}`, rate-limited per account and per IP (failed attempts count), with a per-account daily lockout after N failures and a global failed-redeem breaker, codes bound to a region, the HMAC key separate from `JWT_SECRET` and per region, same error for unknown, expired and exhausted codes, the code never logged (added to `SENSITIVE_KEYS`).
  - **Direct grant by e-mail** through the CLI (`python -m app.admin entitlement grant --kind ads_removed`, e-mail read from stdin), audited (`admin_audit` without the e-mail in clear text beyond the account id); a grant to an unknown e-mail is refused, no user enumeration over HTTP.
  - `GET /v1/me/entitlements` returns the effective set; the app **caches it daily** (and on sign-in) and treats a failed refresh as "keep the last known value" for a bounded grace period. Ads logic reads the cache only and never appears on reminder or dose screens.
- **Inventory:** `entitlements`, `promo_redemptions`, `purchases`, `auth_identities` and the backend `admin_audit` go into `TABLE_CLASSIFICATION`, erasure and export.
- **Analytics event allowlist.** `docs/spec/analytics-events.md`; typed Dart events; a test that payload keys stay inside the allowlist and that no medical field or id appears; catalog and scan events are forbidden (no gtin, product ids or `q`); a no-op sink until an AppMetrica key exists.
- **Remote config.** `GET /v1/config` (ad network and units per region, feature flags), read in Settings; a test asserts that ad placements are never configured for reminder or dose screens.
- **Client region selection.** Locale-based suggestion with confirmation at registration; base URLs per region from dart-defines. IP geolocation is deferred (needs a licensed database).
- **Sentry wiring.** SDK initialization using the existing `scrub_sentry_event`, inert without a DSN.

### Needs the owner (accounts, legal, deployment, stores)

- **Accounts:** OAuth client registrations (Apple, with a legal entity for Apple guideline 5.1.1(ix); Google; VK; Yandex); store and merchant accounts (RuStore Pay, App Store, Google Play, Xiaomi, Samsung); AppMetrica and Yandex Ads accounts and mediation; Sentry hosting per region.
- **Legal:** health-data consent document, privacy policy, RKN notification (including cross-border for FCM, APNs and ML Kit), GDPR representative, the Phase 4 Legal review list above, promo and ad-removal terms.
- **Deployment:** RU and EU hosting with IaC apply, domains, TLS, backups and monitoring, per-region catalog deployment and import runs.
- **Stores:** store listings, review submissions, signing keys and publication.
