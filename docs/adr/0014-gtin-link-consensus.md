# ADR 0014 — GTIN link consensus (Phase 4)

- Status: accepted
- Date: 2026-10-21
- Scope: TZ §2.1 ("Связка «GTIN → продукт» создаётся только выбором продукта из справочника;
  становится общей после N совпадающих подтверждений, спорные — в админке. Ручной состав
  остаётся личным"), §2.1 ("глобальный сервис без персональных данных"); backend
  `app/services/catalog_contributions.py`, `app/catalog_client.py`, ARQ cron
  `push_gtin_confirmations`, `medications.gtin_link_shared`; catalog
  `catalog/catalog/domain/consensus.py`, `api/internal.py`, `api/admin.py`,
  `services/{ingest,decisions}.py`, `admin/cli.py`, revision `c0005_consensus`
- Related: owner decisions D2 and D8 (`docs/phase4-plan.md`), ADR 0011 §4 (trust zones),
  ADR 0012 §2 (consensus package ids), ADR 0013 §2 (only shareable GTINs), ADR 0015 §4
  (opt-in in the app), `.claude/rules/privacy.md` rules 1, 3, 6, 7

## Context

Official sources rarely carry GTINs (openFDA does through NDC; EMA and the RU open sources
mostly do not), so most package GTINs will be learned from users: a user scans a pack,
picks the product it belongs to, and the pair `(gtin, product_id)` is a candidate link. The
TZ wants a link to become shared after N matching confirmations, with disputes handled by
an admin, and the catalog must hold no personal data. A naive design — the app posting
`(gtin, product_id)` to the catalog — would give the catalog a per-request record of who
takes what, even without an account id (IP, timing, install id). A Sybil could also promote
a wrong link with a few fake installs.

## Decision

### 1. A confirmation is a fact about a medication, counted in the region

A confirmation is a **live medication** (not tombstoned) in a region's backend database
whose `gtin` is shareable (ADR 0013 §2), whose `catalog_product_id` is set, and whose
`gtin_link_shared = true`. The catalog never sees the medication, the user or the device.

### 2. Opt-in per link, default off (D2)

- `gtin_link_shared` is a boolean on the medication, **false by default**, set only through
  a checkbox shown at link time ("Анонимно помочь другим распознавать эту упаковку"), only
  when the GTIN is shareable, the product is chosen and the backend reports
  `catalog_contributions_enabled` in `/v1/me/features`.
- Only full-access roles (owner, guardian) may set it; an editor's upsert that changes it is
  rejected with `forbidden_field` (ADR 0015 §4). It is never projected to relatives.
- Clearing the checkbox, unlinking the product, deleting the medication or erasing the
  account all remove the confirmation at the next snapshot (§3). No separate withdrawal
  flow is needed; this is the retention rule for contributions (privacy rule 7).
- `gtin_link_consent_version` comes from the app: it sends the version of the checkbox text it displayed in the upsert; the server validates it against its supported set (unknown → `422`) and stores it with its own timestamp (`gtin_link_consented_at`).
- The DB CHECK `NOT gtin_link_shared OR (gtin IS NOT NULL AND catalog_product_id IS NOT NULL)`
  keeps the flag meaningful; a second CHECK `deleted_at IS NULL OR NOT gtin_link_shared` ties it to live rows.
- **Consent follows the pair.** The server resets `gtin_link_shared` to false and clears the
  consent record (`gtin_link_consent_version`, `gtin_link_consented_at`, server-set,
  `NEVER_PROJECTED`, erased with the row) whenever `gtin` or `catalog_product_id` changes,
  unless the same upsert comes from a full-access role and sets it true. The app resets it on
  every re-link, including the D4 prompt, and offers the checkbox again.
- Strict environments refuse `CATALOG_CONTRIBUTIONS_ENABLED=true` until Phase 5 consent
  records exist.
- **Switching the feature off retracts.** With contributions disabled and the catalog URL and
  token still configured, the worker sends one empty complete snapshot (then nothing until the
  feature is enabled and disabled again); `CATALOG_CONTRIBUTIONS_RETRACT=true` forces it. A
  region that stops reporting also fades out: its counts stop counting after
  `CATALOG_INGEST_MAX_AGE_HOURS` (72) and a catalog maintenance job deletes them.

### 3. Aggregation and transfer: counts only, per region

- ARQ cron `push_gtin_confirmations` in the regional backend, every
  `CATALOG_CONTRIBUTION_INTERVAL_SECONDS` (3600), enabled by `CATALOG_CONTRIBUTIONS_ENABLED`
  (default false) and `CATALOG_INTERNAL_URL` + `CATALOG_INGEST_TOKEN`.
- One SQL aggregate: for each `(gtin, catalog_product_id)`, the number of **distinct profile
  owner users** (two managed profiles of one owner count once) whose account is verified,
  not `pending_deletion`, and created at least `CATALOG_CONTRIBUTION_MIN_ACCOUNT_AGE_DAYS`
  (7, D8) ago. The partial index `(gtin, catalog_product_id) WHERE gtin_link_shared AND
  deleted_at IS NULL` serves it.
- The result is sent as a **full snapshot** in pages:
  `PUT /internal/v1/regions/{region}/gtin-confirmations
  {generation, page, complete, items: [{gtin, product_id, count}]}`. Nothing else leaves the
  regional backend (D2). Only items with `count ≥ CATALOG_CONTRIBUTION_MIN_REPORTED_COUNT`
  (2) are sent, so a single person's link never leaves; the catalog CHECK is
  `confirmations ≥ 2`. The job logs the number of items and the HTTP status only.
- Catalog ingest: the bearer token must match the path region (`CATALOG_INGEST_TOKENS` =
  `region:sha256` list; the name starts with `ru` or `eu`, rotation variants `ru-next`; validated
  at startup against `CATALOG_ACCEPTED_REGIONS`, where empty means the ingest takes nothing)
  → otherwise `403`. Pages are staged by `generation`; on
  `complete` the region's rows in `gtin_link_candidates` are replaced atomically. A replayed
  page or generation is idempotent (a re-sent page replaces that page's rows; the staged row
  count is checked against the cap after every page); only a **newer** generation discards an
  unfinished older one; a generation below the committed **or the staging** one is `409
  generation_stale` and names the generation to use next (the sender retries once); a generation
  more than a day ahead of the catalog's clock is `422`; `python -m catalog.admin ingest reset
  <region>` (audited) clears a poisoned state. Only the GTINs whose `(product, count)` rows
  changed between the committed and the new snapshot are re-decided. Unknown or withdrawn product ids
  are dropped and counted, never failing the page.
- Because every snapshot is complete, an opt-out, a deletion or an erasure lowers the
  count automatically; no per-user signal is ever sent.

### 4. Decision rule (D8)

`decide(official, counts, current, thresholds) -> Decision` is a pure function in
`catalog/catalog/domain/consensus.py`, run for every GTIN whose rows changed in an ingest, under
**one global advisory lock** per transaction (a lock per GTIN would exhaust the lock table for a
large snapshot and could deadlock two regions). The same lock covers admin resolves, the
maintenance job and the re-decision after an importer run, which is how an official row that
appears or is withdrawn moves the decision. Counts are summed over regions in a global
deployment; in the per-region default there is one region.

With `c1` the top product's count and `c2` the runner-up's. The rows are evaluated **in
this order and the first match wins**, pinned by a table test (`locked` is checked first):

| Condition | Result |
|---|---|
| the GTIN is `locked` by an admin | the admin's product; counts are ignored |
| `official` exists and no other product has `count ≥ N` | `promoted` to the official product (unchanged; official rows are never overridden) |
| `official` exists and another product has `count ≥ N` | `disputed` |
| already `promoted` (consensus) and no other product has `count ≥ N` | stays `promoted`; if a competitor reaches N → `disputed` |
| `c2 ≥ CATALOG_CONSENSUS_DISPUTE_MIN` (2) | `disputed` |
| `c1 ≥ CATALOG_CONSENSUS_MIN_CONFIRMATIONS` (3) | `promoted`: a `consensus` package (`uuid5(... "consensus:package:<gtin>:<product_id>")`, ADR 0012 §2) and a `gtins` row with `origin = consensus` |
| otherwise | `pending` |

- Two young accounts can never hide an official or an already promoted GTIN: only a competitor reaching N disputes them.
- Promotion is **sticky**: a later drop of counts does not demote (users rely on the link);
  only an admin can `reject` or `lock`.
- A `disputed` GTIN answers `{status: "disputed"}` without a product on
  `/v1/gtins/lookup`; `rejected` answers `unknown`; `locked` keeps the admin's product and
  ignores counts.
- The thresholds are settings (`CATALOG_CONSENSUS_MIN_CONFIRMATIONS=3`,
  `CATALOG_CONSENSUS_DISPUTE_MIN=2`, backend `CATALOG_CONTRIBUTION_MIN_ACCOUNT_AGE_DAYS=7`),
  validated ≥ 1, and the decision table is covered by a unit test to ~100 %.

### 5. Admin: endpoints and CLI, no UI

- `GET /admin/v1/disputes` (paged), `POST /admin/v1/gtins/{gtin}:resolve
  {action: promote | reject | lock, product_id?}`, `GET /admin/v1/import-runs`.
- **Admin attribution.** An admin `promote` is sticky like a consensus promotion: the next
  automatic evaluation attributes it to `auto` / `sticky_promotion` again, and a competitor
  that still holds N confirmations disputes it again. `lock` and `reject` are final and are never
  changed by counts. `admin_audit` keeps the history, including the decision each action replaced.
  Use role labels (`ops-1`, `oncall`), not personal names, as token names; audit rows are kept
  for the life of the catalog unless a retention rule says otherwise.
- Bearer tokens from `CATALOG_ADMIN_TOKENS` (`name:sha256` list, constant-time compare, two
  per role for rotation; tokens generated with ≥ 32 characters, the catalog holds digests),
  rate-limited, served by a separate ASGI app on a private listener, never routed by the public proxy
  (ADR 0011 §4). Every action is written to `admin_audit` with the token's name, action,
  GTIN and product id — no personal data.
- `python -m catalog.admin disputes list | resolve <gtin> --action … [--product …]`
  runs against the database inside the container for operators without HTTP access.
- The TZ's "админка" is this: endpoints plus CLI; a web UI is out of scope.

### 6. Sybil resistance and abuse

- Confirmations need an account that is verified by e-mail, not pending deletion and at
  least 7 days old; each owner counts once per `(gtin, product)` regardless of profiles,
  devices or re-links.
- A wrong link needs N = 3 such accounts agreeing; a single competing confirmation at 2
  already parks the GTIN as disputed for the admin.
- Restricted GTINs are filtered in the backend query and refused by the catalog's CHECK.
- Rate limits and body caps on the ingest endpoint; a snapshot with more than
  `CATALOG_INGEST_MAX_ITEMS` items is refused with `413`.

## Consequences

- Backend: one cron job, one HTTP client, settings in `settings_catalog.py`; `personal_data.py`
  documents that only aggregates leave and that no new table is added.
- Catalog: tables `gtin_link_candidates`, `gtin_link_decisions`, `admin_audit`; revision
  `c0005_consensus` (`gtin_link_decisions` itself already exists from `c0004_search_support`, 4.5,
  because the public lookup reads it).
- Promotion latency is up to one interval (an hour) after the third confirmation; the user
  who linked a pack sees their own link immediately on their medication regardless.
- The catalog holds counts per region that could, in a very small region, be close to
  "one person uses this product"; counts are never exposed publicly (lookup returns status
  and product only), and the admin surface is private. Legal item 5 of the plan asks
  counsel whether such counts are anonymous data.
- **Residual Sybil oracle.** Two accounts of the minimum age that confirm a pair, plus the
  public `found` / `disputed` answer, reveal that at least one more person confirmed the same
  pair (promotion needs N = 3; a runner-up with 2 disputes). The thresholds are an owner
  decision (D8) and were not changed; the legal review (plan item 5) should weigh this against
  the value of the dispute rule.
- **Cross-border and anonymity.** In a per-region catalog no personal data crosses a border; a
  global deployment sends counts across regions. Whether a count is anonymous data in a very
  small region, and whether sending it from RU to a catalog outside RU is a cross-border
  transfer, are legal questions (plan item 5), not settled by this ADR.
- In a global deployment, aggregates cross regions (not personal data); the per-region
  default avoids even that.

## Alternatives considered

- **Clients post confirmations to the catalog** (with or without a pseudonym): gives the
  catalog per-event records about what people take; Sybil-prone; rejected.
- **Hashed user ids in the catalog**: pseudonymous personal data under GDPR and 152-FZ,
  which the catalog must not hold; rejected.
- **Signed anonymous tokens (blind signatures) per account**: strong, but far more
  machinery than Phase 4 needs; the regional aggregate gives the same Sybil property with
  one SQL query.
- **Opt-in once per account** instead of per link: simpler UI, but the owner chose a
  per-link choice at link time, default off (D2).
- **Opt-out by default**: more data, but health-related contribution needs explicit
  consent (privacy rule 6); rejected.
- **Automatic demotion when counts drop**: would make links flap as users leave; admin
  tools cover real errors.
