# Catalog sources: terms and attribution

The catalog holds public reference data only. Every source has a row in `catalog.sources` (`license`,
`attribution`, `url`, seeded by migration `c0002`); `GET /v1/sources` (milestone 4.5) serves it to the
Settings -> About screen. This file keeps the terms behind those rows and the exact attribution strings.

Status of the entries below: written in milestone 4.4 from the sources' published terms, **without a legal
review**. Re-read the linked pages and have counsel confirm before the first public launch
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

## Parsing dependencies

Phase 4.4 adds no parser dependency: JSON is read by `catalog/importers/jsonstream.py` and RRF by
`catalog/importers/rrf.py` (both standard library only). `httpx` (BSD-3-Clause), already a development
dependency, is now a runtime dependency for `fetch`.
