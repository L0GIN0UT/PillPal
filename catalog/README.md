# PillPal catalog service

Global medicine catalog: public reference data only. It has **no users, accounts, devices or tokens of
end users**, and it must never import the regional backend (`app.*`). Both rules are enforced by tests
(`tests/test_privacy_boundary.py`). Milestone 4.1 is the skeleton (health probes, logging, error envelope, rate limiting, database
baseline); 4.3 adds the data model and the importer framework; 4.4 adds the openFDA NDC and RxNorm importers and 4.4b the RU sources (ESKLP and the manual GRLS export behind
flags, Roszdravnadzor recall flags; terms and attribution: [`LICENSES.md`](LICENSES.md)); 4.5 adds the public search, lookup, card and sources endpoints.

## Run

```bash
docker compose -f ../infra/docker-compose.yml up -d postgres redis
PGPASSWORD=postgres createdb -h localhost -U postgres pillpal_catalog_test   # once
export CATALOG_DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_catalog_test
export CATALOG_REDIS_URL=redis://localhost:6379/3
uv sync --frozen
uv run ruff check . && uv run ruff format --check . && uv run mypy catalog
uv run pytest --cov=catalog --cov-fail-under=85     # the tests DROP the public and catalog schemas
uv run alembic upgrade head
uv run uvicorn catalog.main:app --reload
```

## Settings (environment)

| Variable | Default | Meaning |
|---|---|---|
| `CATALOG_DATABASE_URL` | required | PostgreSQL URL (own database, never the regional one) |
| `CATALOG_REDIS_URL` | `redis://localhost:6379/0` | rate limits only; the service works without Redis (fail-open) |
| `ENVIRONMENT` | `dev` | `dev` / `test` / `staging` / `prod` |
| `CATALOG_ADMIN_TOKENS`, `CATALOG_INGEST_TOKENS` | empty | comma-separated `name:sha256hex` (SHA-256 of a random secret of >= 32 characters, e.g. `python -c "import secrets,hashlib; s=secrets.token_urlsafe(48); print(s, hashlib.sha256(s.encode()).hexdigest())"`); both required in staging and prod **by the private app** (it refuses to start without them; the public service is deployed without them). Used by the **private** app only (see "Consensus"): admin tokens by `/admin/v1/*` (the name goes to `admin_audit`), ingest tokens by `/internal/v1/*` (the part of the name before the first `-` or `_` is the region the token speaks for: `ru`, `eu`, rotation `ru-next`; a token whose name does not start with a region can ingest nothing) |
| `CATALOG_CONSENSUS_MIN_CONFIRMATIONS`, `CATALOG_CONSENSUS_DISPUTE_MIN` | 3 / 2 | N matching confirmations promote a link; a runner-up with the dispute minimum parks the number as disputed (owner decision D8) |
| `CATALOG_INGEST_PAGE_MAX_ITEMS`, `CATALOG_INGEST_MAX_ITEMS`, `CATALOG_INGEST_BODY_MAX_BYTES` | 1000 / 200000 / 262144 | items per page, items per snapshot (`413 payload_too_large` beyond either), body cap of the private app |
| `CATALOG_ADMIN_PAGE_MAX` | 100 | page size cap of the admin lists |
| `CATALOG_ACCEPTED_REGIONS` | empty | regions whose backends may report (`ru`, `eu`); empty = the ingest takes nothing. Ingest token names must start with an accepted region (startup refuses otherwise) |
| `CATALOG_INGEST_MAX_AGE_HOURS` | 72 | a region whose last committed snapshot is older stops counting; the maintenance job deletes its counts (retention) |
| `CATALOG_INGEST_MAX_GENERATION_SKEW_SECONDS` | 86400 | a generation further ahead of the clock is `422 generation_in_future` |
| `CATALOG_MAINTENANCE_INTERVAL_SECONDS` | 3600 | the private app expires stale regions and re-decides every GTIN that has a decision or a candidate |
| `CATALOG_PRIVATE_RATE_LIMIT_IP_MAX` / `CATALOG_PRIVATE_RATE_LIMIT_TOKEN_MAX` | 60 / 1000 | private listener, per window: the IP bucket (`private-ip`) counts **failed authentication only**; a valid caller is limited per token (`private-token`), so a large snapshot (many pages) is not blocked. A `429` carries `Retry-After`; the backend waits and resends the page |
| `CATALOG_AUDIT_RETENTION_DAYS` | 730 | `admin_audit` rows older than this are purged by the maintenance job (owner default: two years) |
| `CATALOG_RATE_LIMIT_SALT` | random per process in dev/test | HMAC key of rate-limit buckets; **required in staging and prod**, because a per-process random salt would split the buckets of several processes and reset on every restart |
| `CATALOG_RATE_LIMIT_UNAVAILABLE_SECONDS` | 30 | after a Redis failure the limiter skips Redis (fail-open) for this long and logs one warning |
| `FORWARDED_ALLOW_IPS` | empty (image) | addresses whose `X-Forwarded-For` uvicorn believes: the reverse proxy's address or subnet, **never `*`** (any client could then pick the IP the rate limiter sees). Empty trusts nobody, not even loopback; then every client looks like the proxy and the IP bucket becomes global |
| `CATALOG_RATE_LIMIT_WINDOW_SECONDS`, `CATALOG_RATE_LIMIT_IP_MAX`, `CATALOG_RATE_LIMIT_INSTALL_MAX` | 60 / 240 / 60 | fixed window per IP and per `X-Catalog-Install` |
| `CATALOG_SEARCH_STATEMENT_TIMEOUT_MS` | 300 | PostgreSQL cancels a public read that runs longer; the answer is `503 catalog_timeout` |
| `CATALOG_SEARCH_TRIGRAM_THRESHOLD` | 0.5 | `word_similarity` threshold of the typo path |
| `CATALOG_SEARCH_MAX_LIMIT`, `CATALOG_SEARCH_ENTRY_CAP`, `CATALOG_SEARCH_SUBSTANCE_CAP` | 20 / 200 / 25 | result cap per request; entries and substances considered before ranking |
| `CATALOG_REQUEST_BODY_MAX_BYTES` | 4096 | larger bodies are refused with `413 payload_too_large` before they are read |
| `CATALOG_IMPORTER_ESKLP_ENABLED` | `false` | ESKLP has no published license text: `fetch` and `run` refuse until the owner sets this to `true` (D1; checklist below) |
| `CATALOG_IMPORTER_GRLS_ENABLED` | `false` | same gate for the GRLS manual-export importer: `run` refuses, and `fetch` does not exist for it |
| `CATALOG_IMPORTER_STALE_RUN_MINUTES` | 360 | a `running` import row older than this is marked `failed`/`stale` when the next run of the source starts |
| `LOG_LEVEL` | `INFO` | |
| `CATALOG_DB_POOL_SIZE` | 5 | |
| `RUN_MIGRATIONS` | `0` | Docker entrypoint applies migrations when `1` |

## Data model and importers (4.3)

Revisions `c0002_catalog_core` (sources seeded once, `import_runs`, substances, compositions, products,
packages, `gtins` keyed by `(gtin, source)`, `recall_flags`) and `c0003_search_entries` (generated `norm` and
`tsv`, GIN indexes). Ids are UUIDv5 over a pinned namespace (`catalog/domain/identity.py`, ADR 0012), so every
regional catalog computes the same ids. `catalog.gtin_check_digit_ok` / `catalog.gtin_is_shareable` implement
`docs/spec/gtin.md` section 3 from `gtin14` only and back the `gtins` CHECK; `tests/importers/test_gtin_sql.py`
runs the shared vectors through them.

```bash
# a run loads one snapshot directory: parse (pure) -> staging -> upsert by id -> withdraw missing -> search entries,
# in one transaction; the run is recorded in catalog.import_runs (counts, sha256, error code, never record text)
uv run python -m catalog.importers run --source fixture --snapshot tests/fixtures/fixture/v1
uv run python -m catalog.importers run --source fixture --snapshot tests/fixtures/fixture/v2 --no-withdraw
uv run python -m catalog.importers fetch --source <source> --out DIR     # network sources only (4.4+)
```

### openFDA NDC and RxNorm (4.4)

```bash
# order matters once: RxNorm first, so openFDA products link to the SCD compositions right away
# (a later openFDA run re-links products that were imported before RxNorm)
uv run python -m catalog.importers fetch --source rxnorm --out /data/rxnorm            # --release MMDDYYYY, --expect-sha256 HEX
uv run python -m catalog.importers run --source rxnorm --snapshot /data/rxnorm
uv run python -m catalog.importers fetch --source openfda_ndc --out /data/openfda
uv run python -m catalog.importers run --source openfda_ndc --snapshot /data/openfda
```

- **Order:** load RxNorm before openFDA, and re-run `run --source openfda_ndc` after every new RxNorm
  release: products link to the first candidate composition that exists (SCD by rxcui, else the product's own
  local composition), and only that re-run moves them to the SCD. `run` prints `warning: products_unlinked=N`
  when a product found no composition at all.
- `fetch` uses https only, an allow-list of hosts (also for every redirect hop), a byte cap on the decoded stream
  and the archive guards of 4.3. `fetch` refuses a non-empty `--out`, and a failed fetch leaves nothing behind.
  RxNorm: `--expect-sha256` pins the archive and the printed `sha256` is the archive's; openFDA publishes no
  checksums, so its printed `sha256` is that of the snapshot directory (the value `import_runs` records).
  Keep the printed RxNorm `sha256` and pass it to the next fetch of the same release as `--expect-sha256`.
  An openFDA snapshot must hold the complete set of partitions `drug-ndc-NNNN-of-MMMM.json`; a partial one
  is refused (`snapshot_incomplete`), because a run withdraws every product the snapshot lacks.
- `parse` is lazy and the loader writes in batches of `RECORD_BATCH_SIZE` records, so memory does not grow with
  the file (a local snapshot directory is read at run time and is trusted as it lies on disk: keep it
  owner-only and do not modify it between `fetch` and `run`; openFDA: `jsonstream.py` walks the JSON incrementally; RxNorm: RRF files line by line, memory
  proportional to the kept concepts). An importer yields all substances, then compositions, then products;
  a snapshot out of that order is refused (`records_out_of_order`).
- Records an importer drops (not finished, vaccine, malformed, duplicate, unusable SCD) are counted by reason in
  `import_runs.counts.parse_skipped`, never listed.
- openFDA products with `openfda.rxcui` link to the first rxcui that exists as an RxNorm SCD composition;
  products without one get a source-local composition (`source_key` = `local:v1:<sha256>`).


- Exit codes: 0 ok, 1 failed (code on stderr), 2 usage, 3 refused (disabled source, run in progress, fixture in
  staging/prod).
- Rows are never deleted: a row missing from a snapshot gets `withdrawn_at` and stays resolvable by id.
  `--no-withdraw` is for partial manual exports (GRLS).
- `fixture` is synthetic and development-only (it registers its own `sources` row); the CLI refuses it when
  `ENVIRONMENT` is `staging` or `prod`. `esklp` and `grls_manual` refuse unless their flags are set.
- Guard for every source: a snapshot that would withdraw more than 30% of any kind of row (products, packages,
  compositions, substances, GTINs) of a source with 100 or more live rows of that kind is refused as
  `snapshot_shrunk` (a partial or damaged file); `--no-withdraw` overrides it knowingly.
- A run never stays `running`: cancellation and interrupts mark it `failed` (`import_aborted`); after a hard kill
  the next run takes over a row older than `CATALOG_IMPORTER_STALE_RUN_MINUTES`.
- `ENVIRONMENT` defaults to `dev`, so the `fixture` source is allowed when it is unset; set it to `staging` or
  `prod` on real deployments (those two also require the service tokens).

### RU sources (4.4b)

```bash
# ESKLP (flag!): the operator names the file, nothing is scraped. Load RxNorm first only if the file carries rxcui.
export CATALOG_IMPORTER_ESKLP_ENABLED=true            # the owner's act, after the checklist below
uv run python -m catalog.importers fetch --source esklp --out /data/esklp --url https://esklp.egisz.rosminzdrav.ru/<file> [--expect-sha256 HEX]
uv run python -m catalog.importers run --source esklp --snapshot /data/esklp
# Roszdravnadzor recall flags (needs the ESKLP flag too; run after ESKLP, the card joins by registration number)
uv run python -m catalog.importers fetch --source ru_roszdravnadzor --out /data/rzn --url https://roszdravnadzor.gov.ru/opendata/<file>.csv
uv run python -m catalog.importers run --source ru_roszdravnadzor --snapshot /data/rzn
# GRLS (flag!): a manual monthly Excel export saved as .xlsx in a directory; there is no fetch
export CATALOG_IMPORTER_GRLS_ENABLED=true
uv run python -m catalog.importers run --source grls_manual --snapshot /data/grls
```

- **ESKLP input:** one `.xlsx` (a sheet is recognised by its header: KLP key + trade name = trade items, which
  may repeat INN / form / dosage; SMNN key + INN = SMNN rows) or `.xml` files per the passport (`<smnn>` and
  `<klp>` elements). Header wording and element names are matched by alias (`importers/esklp_source.py`) and
  are **verified only on synthetic fixtures**: smoke-import a real file first. A file without the expected
  columns, with no trade items, truncated, or with a DOCTYPE is refused before anything is written.
- **Result:** SMNN -> source-local substances (`inn:<folded name>`, `name_ru`) and compositions (`complete`
  only with a form and a parsed strength for every ingredient; a combination INN needs one strength per part);
  KLP -> a `ru` product with one package; `barcode` (8/12/13/14 digits, one or several) -> GTIN-14 packages.
  Restricted numbers, bad check digits and numbers printed on several KLP are dropped and counted
  (`counts.parse_skipped`). A column `rxcui` (optional) maps a single-ingredient INN onto the RxNorm substance
  when that exists, otherwise the local substance is used.
- **Withdrawal:** a re-import withdraws KLP, SMNN and packages missing from the file. Roszdravnadzor flags are
  never deleted; GRLS never withdraws (a manual export is partial).
- **GRLS:** attaches the export's barcodes to the live ESKLP package of the same registration number only when
  exactly one package carries it (`counts.package_links_matched|ambiguous|unmatched`); it creates no products.
  Run it after ESKLP (the CLI warns when links found nothing). A manufacturer that is an individual entrepreneur
  (`ИП`, `Глава КФХ`) is not stored (natural person); `parse_skipped.manufacturer_individual` counts them.
- A successful run sets `sources.enabled = true` for ESKLP, Roszdravnadzor and GRLS so `GET /v1/sources` serves
  their attribution; a source whose run never succeeded stays hidden.
- **Owner checklist before `CATALOG_IMPORTER_ESKLP_ENABLED=true`** (docs/phase4-plan.md 4.4b): (1) download the
  file from `esklp.egisz.rosminzdrav.ru` and confirm it needs no authentication; (2) send the written request to
  Минздрав / ЦНИИОИЗ about use in a commercial app; (3) get answers to legal review items 1-2; (4) smoke-import
  the real file into a scratch database and compare the counts with the portal; only then set the flag. The same
  applies to the GRLS flag with research questions Q3-Q4.

### EMA (4.8)

```bash
# Public data, no flag. --url is optional (default: the EMA "Medicines output" report address, unverified).
uv run python -m catalog.importers fetch --source ema --out /data/ema [--url https://www.ema.europa.eu/<file>.xlsx] [--expect-sha256 HEX]
uv run python -m catalog.importers run --source ema --snapshot /data/ema
```

- **Result:** each authorised human medicine -> an `eu` product (key: EMA product number, `manufacturer` = the
  marketing authorisation holder) linked to an **incomplete** composition of its active substances (source-local
  substances `name:<folded name>`, `name_en`). No form, strength, package or GTIN; `complete` is never true.
  Withdrawn / suspended / refused / veterinary rows are counted in `counts.parse_skipped` and a re-import
  withdraws what the file no longer lists.
- **Owner smoke import (format is synthetic only):** download the real workbook, run `fetch`/`run` into a scratch
  database and check: the header was found (otherwise `missing_columns`: the wording in `ema.ALIASES` differs);
  the number of products is near the number of authorised human medicines on the EMA site; `parse_skipped`
  counts look plausible (`not_authorised`, `not_human`); multi-substance cells are split correctly (a name with a
  comma would be split); `sources.ema` shows the attribution afterwards. Fix `ALIASES` / the status values if not.
  **The first successful run sets `sources.enabled = true` for `ema`**, so the EMA attribution (and the data
  served from the catalog) become public in `GET /v1/sources`; run the smoke import against a scratch
  database, not the one serving the app.

## Public API (4.5)

Contract: `catalog/openapi.json` (refresh with `uv run python -m catalog.openapi_snapshot`; a test fails while
it is stale). No credentials: a request with an `Authorization` header is refused with
`400 unexpected_authorization`. Every route is rate limited per IP and per `X-Catalog-Install` (`429`).
Lookups are `POST` with JSON bodies so nothing a person types or scans lands in a URL; responses to them are
`Cache-Control: no-store`.

| Route | Body / answer |
|---|---|
| `POST /v1/search` | `{q (2-100 chars after trim), lang: ru\|en, market?: ru\|us\|eu, kind?: product\|substance, limit?}` -> `{mode: text\|gtin, results: [{kind, id, name, market, country, manufacturer, form, substances, withdrawn}]}`. 8/12/13/14 digits run the GTIN path. Order: withdrawn last, own `market` first, then score, then id (D6; no analog list, D9). A Russian INN finds foreign products through `substance_names`. |
| `POST /v1/gtins/lookup` | `{gtin}` -> `{status: found\|unknown\|restricted\|disputed, product, package, composition}`; a malformed number is `422 invalid_gtin`; restricted numbers are never looked up |
| `POST /v1/products/get` | `{id}` -> card `{product, composition (ingredients with substances), packages (with GTINs), recalls}`; unknown id is `404`; withdrawn rows resolve |
| `GET /v1/sources` | enabled sources with `license` and `attribution` for Settings -> About |

Every read runs in one read-only transaction with `statement_timeout` set; the timeout answer carries no SQL
and no input. Revision `c0004_search_support` adds the reverse index `composition_ingredients(substance_id)` and
the `gtin_link_decisions` table the lookup consults (written by the consensus code of 4.7, below).
`tests/api/test_search_performance.py` holds the p95 budget on a generated 60k-product dataset.

## Consensus (4.7, ADR 0014)

Regional backends send **counts**, never people: `PUT /internal/v1/regions/{region}/gtin-confirmations`
with `{generation, page, complete, items: [{gtin, product_id, count >= 2}]}` is a page of the region's complete
snapshot. The catalog stages pages by `generation` and, on the `complete` page, replaces the region's rows in
`gtin_link_candidates` atomically and re-decides every GTIN the old or the new snapshot mentions
(`catalog/domain/consensus.py::decide`, pinned order: locked, official, sticky promotion, dispute at 2, promote
at N = 3, pending), each under a per-GTIN advisory lock.

- The ingest token is bound to its region: wrong or missing token `401`, another region's token `403`. A
  generation below the last committed one is `409 generation_stale`; the committed one is a replay and
  answers `duplicate`; a newer generation discards an unfinished older one; a `complete` page with a missing
  page is `409 snapshot_incomplete` and changes nothing. Unknown or withdrawn product ids and restricted numbers
  are dropped and counted (`dropped`), never failing the page. The log line of a commit carries the region and
  counts only.
- Promotion writes a `consensus` package (`uuid5`, ADR 0012) and the `gtins` row with `origin = consensus`, so
  the lookup and the product card find it; a dispute, a rejection or a drop to pending withdraws that row.
  Promotion is sticky (a later drop of counts does not demote). An admin `lock` or `reject` is final;
  an admin `promote` is sticky like a consensus one.
- **One global lock.** Every writer (ingest commit, admin resolve, maintenance, the re-decision after an
  importer run) takes one advisory lock per transaction, so a snapshot of any size neither exhausts
  `max_locks_per_transaction` nor deadlocks two regions. A commit re-decides only the GTINs whose
  `(product, count)` rows changed. The importers call the same re-decision after a successful run, and the
  maintenance job repeats it, so an official row that appears or is withdrawn moves the decision.
- **Private listener.** `/internal` and `/admin` exist only in `catalog.private_app` (a separate ASGI app on its
  own port, never routed by the public proxy; the public app answers 404, a test asserts it):

  ```bash
  uv run uvicorn catalog.private_app:app --host 0.0.0.0 --port 8001 --no-access-log
  ```

  Both are rate limited (own bucket and limit), authenticate with bearer tokens (constant-time digest
  comparison, rotation by two tokens), publish no `/docs` or `/openapi.json`, and use the same envelope.
  **Deployment:** never publish port 8001 on the public reverse proxy. Reach it from the regional backends
  and operators only: an IP allow-list at the proxy or firewall, or mTLS / WireGuard between the hosts.
  Set `FORWARDED_ALLOW_IPS` for this listener to the address of whatever fronts it (never `*`), otherwise
  every caller shares one rate-limit bucket. Use `https` between hosts.
- **Generations.** A generation below the committed or the staging one is `409 generation_stale` with
  `committed_generation` and `min_generation` in the body (the backend retries once above it); only a newer
  generation discards an unfinished older one. If a region is stuck (a poisoned generation),
  `POST /admin/v1/ingest/{region}:reset` or `python -m catalog.admin ingest reset <region>` forgets its state and
  counts (audited). `python -m catalog.admin maintenance` runs the upkeep once. The upkeep (expire silent
  regions and their unfinished staging, re-decide, purge old audit rows) runs in one worker per interval
  (a Redis `SET NX EX` claim; an unreachable Redis lets every worker run, which is safe).
- **Admin.** `GET /admin/v1/disputes?after=&limit=` (disputed GTINs with candidates, names and counts),
  `POST /admin/v1/gtins/{gtin}:resolve {action: promote|reject|lock, product_id?}`,
  `GET /admin/v1/import-runs`. `promote` of a product other than an official row's is `409
  official_product_differs` (use `lock`). Every action is written to `admin_audit` with the token's name and
  the decision it replaced; rejected attempts are logged by stable code. Name tokens by role (`ops-1`,
  `oncall`), not by person. A `promote` is sticky like a consensus promotion (the next evaluation attributes it
  to `auto` and a competitor still at N disputes it again); `lock` and `reject` are final. Keep audit rows for
  the life of the catalog unless a retention rule is decided.
- **CLI** for operators without HTTP access (inside the container; audited as `cli`):

  ```bash
  python -m catalog.admin disputes list
  python -m catalog.admin resolve 04607012345677 --action lock --product <product-uuid>
  ```

## End-to-end with the app (4.12)

CI runs the app against this service twice, both times with the synthetic `fixture` snapshot and nothing real:
`app/test_e2e/catalog_test.dart` on the host (job `app / e2e`: search -> select -> save -> pull on a second device;
unknown GTIN -> opt-in -> three accounts -> aggregate -> lookup `found`) and the `catalog` phase of the emulator
journeys (the number typed in the scan sheet; there is no camera). Locally, use databases and Redis indexes of
their own (the importer and the tests write to them):

```bash
# once: createdb pillpal_e2e pillpal_catalog_e2e (PostgreSQL; the names must end in _e2e or _test), then, in a shell with the variables below
export CATALOG_DATABASE_URL=postgresql+asyncpg://postgres:postgres@127.0.0.1:5432/pillpal_catalog_e2e
export CATALOG_REDIS_URL=redis://127.0.0.1:6379/3 ENVIRONMENT=test CATALOG_ACCEPTED_REGIONS=ru
export CATALOG_INGEST_TOKEN=any-throwaway-secret-of-at-least-32-characters
export CATALOG_INGEST_TOKENS="ru-e2e:$(printf '%s' "$CATALOG_INGEST_TOKEN" | sha256sum | cut -d' ' -f1)"
(cd catalog && uv run alembic upgrade head \
  && uv run python -m catalog.importers run --source fixture --snapshot tests/fixtures/fixture/v1)
(cd catalog && uv run uvicorn catalog.main:app --port 8002 &)               # public API
(cd catalog && uv run uvicorn catalog.private_app:app --port 8001 &)        # ingest, for the consensus journey
# backend (own database, REGION=ru, ENVIRONMENT=test, LOG_EMAIL_CODES=true, JWT_SECRET, DATABASE_URL, REDIS_URL as in CLAUDE.md), plus
export CATALOG_CONTRIBUTIONS_ENABLED=true CATALOG_INTERNAL_URL=http://127.0.0.1:8001
(cd backend && uv run alembic upgrade head && uv run uvicorn app.main:app --port 8000 > /tmp/backend.log &)
cd app && PILLPAL_E2E_BASE_URL=http://127.0.0.1:8000 PILLPAL_E2E_LOG=/tmp/backend.log \
  PILLPAL_E2E_CATALOG_URL=http://127.0.0.1:8002 \
  PILLPAL_E2E_AGGREGATE_CMD='cd ../backend && uv run python ../.github/scripts/e2e/catalog_aggregate.py' \
  flutter test --concurrency=1 test_e2e/catalog_test.dart
```

- The tests assume a **fresh** catalog database (no counts for the synthetic number yet) and a fresh backend
  database: recreate both before a rerun.
- There is no production endpoint for "run the aggregate now": `.github/scripts/e2e/catalog_aggregate.py` is a
  test-only script that calls the worker's own function once. It refuses (exit 2) unless `ENVIRONMENT=test`, the
  database name ends in `_e2e` or `_test` and `CATALOG_INTERNAL_URL` is a loopback address. It also moves the creation date of the synthetic
  `e2e-catalog-*@example.com` accounts back, because only accounts older than
  `CATALOG_CONTRIBUTION_MIN_ACCOUNT_AGE_DAYS` count (D8).
- On Windows use `127.0.0.1`, not `localhost`, in the URLs: `localhost` resolves to `::1` first and the readiness
  checks time out.

## Deploy checklist (public API)

- `FORWARDED_ALLOW_IPS` is the reverse proxy's address or subnet, never `*`; otherwise every client picks
  the IP the rate limiter sees.
- The public API needs read access only: run it with a read-only database role (the importer and migrations
  use another one). Every request already runs `SET TRANSACTION READ ONLY` as a second line of defence.
- The reverse proxy writes no access log with the URI or the remote address (ADR 0015 section 3); uvicorn
  runs with `--no-access-log`.

## Database role

`infra/catalog-db/init.sh` (compose service `catalog-db`) creates the database `pillpal_catalog` and a
dedicated role `catalog`: not a superuser, owner of that database only, `CONNECT` on the backend's database
revoked from `PUBLIC`. `pg_trgm` and `unaccent` are trusted extensions, so the migration runs as that role
(tested in `tests/test_provisioning.py`). The `catalog` service gets only `CATALOG_*`, `ENVIRONMENT`,
`LOG_LEVEL` and `FORWARDED_ALLOW_IPS`, never the backend's `.env`. The script also sets
`log_statement=none`, `log_min_duration_statement=-1` and `log_parameter_max_length_on_error=0` on the catalog
database; outside compose, apply the same to your database.

With `CATALOG_READER_PASSWORD` the script also creates `catalog_reader` (`CATALOG_READER_USER`): LOGIN, no
inheritance, `CONNECT` and `USAGE` on the schemas, `SELECT` on the tables the owner creates now and later
(default privileges), nothing else. The public service connects as it (it writes nothing: reads run in
read-only transactions, `/readyz` is `SELECT 1`; `tests/test_provisioning.py` runs its read paths as that
role). The script also revokes `CONNECT` on the `postgres` database from `PUBLIC`. Without the password no
reader is created (local development uses the owner role for everything). Migrations always run as the owner.

## Deployment (personal staging stack)

`infra/staging/docker-compose.yml` runs the catalog next to the backend (owner guide: `docs/staging.md`
section 12). What the stack decides:

- **Services.** `catalog-postgres` (own PostgreSQL 16 container and volume, statement logging off),
  `catalog-db` (one-shot: database and non-superuser role via `infra/catalog-db/init.sh`), `catalog` (public
  listener, `127.0.0.1:8081`, read routes only), `catalog-private` (`catalog.private_app` on 8001: regional
  ingest, admin and the maintenance loop; **no published port**, no proxy route), and `catalog-tools` (profile
  `tools`: importers and the admin CLI as `docker compose run --rm`, files in `./catalog-import` owned by uid
  10001). Its own Redis (`catalog-redis`: own password, no port, no volume, no persistence). The services receive only `CATALOG_*`, `ENVIRONMENT`,
  `LOG_LEVEL` (from the stack's `CATALOG_LOG_LEVEL`, not the backend's) and `FORWARDED_ALLOW_IPS`, and `RUN_MIGRATIONS=0`: the deploy runs
  `docker compose run --rm catalog-tools alembic upgrade head` as a step, like the backend's (the owner role;
  the public service connects as the read-only `catalog_reader` and holds no token digests).
- **Image.** `ghcr.io/<owner>/pillpal-catalog:<commit sha>`, built by `deploy-staging.yml` from `catalog/` in
  the same job as the backend image (the only job with `packages: write`); the compose file takes the tag from
  `PILLPAL_IMAGE_TAG`.
- **Proxy.** The catalog has its own host (`CATALOG_DOMAIN`). The Caddyfile routes the six public routes only
  and answers 404 for everything else, so `/admin*` and `/internal*` never reach the service; no access log, and
  the Caddy error log drops URI, address and headers. An nginx must also set `access_log off` for that host.
  `FORWARDED_ALLOW_IPS` is the compose subnet, never `*`.
- **Backup.** The catalog database is not dumped: public data that the importers rebuild, counts that return
  within an hour; only admin decisions and the audit trail are lost with the volume.
- **Backend link.** `CATALOG_INTERNAL_URL` and `CATALOG_INGEST_TOKEN` are passed through and empty by default:
  staging refuses `CATALOG_CONTRIBUTIONS_ENABLED`, and the backend requires https for the private listener.
- **Alerts.** `catalog_push_failed` while contributions are disabled means the retraction fails (counts stay until
  `CATALOG_INGEST_MAX_AGE_HOURS`, 72 h); also `catalog_generation_stale`. See `docs/staging.md` 12.3.

## Privacy rules

- Access log: method, route template, status, duration and a random request id. Never the query string,
  body, client IP, user agent or `X-Catalog-Install`.
- Rate-limit Redis keys are HMAC hashes with a one-window TTL; nothing is stored in PostgreSQL.
- PostgreSQL statement logging is off for this database (see above).
- No CORS, no cookies, no authentication on public routes.
