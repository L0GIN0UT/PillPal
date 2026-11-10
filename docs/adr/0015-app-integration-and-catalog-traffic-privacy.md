# ADR 0015 — App integration and catalog traffic privacy (Phase 4)

- Status: accepted
- Date: 2026-10-22
- Scope: TZ §2.1 (free text kept, optional catalog link, scan, "подсказка о пересечении",
  "тот же состав → привязать упаковку"), §3, §5 "Фаза 4"; backend `medications` table and
  `MedicationFields` / `MedicationData` / `MedicationOut`, `domain/privacy.py`,
  `domain/write_access.py`, `services/sync.py`; app `data/catalog/`, drift `catalog_cache`,
  `features/catalog/`; `packages/pillpal_core/lib/src/catalog/composition_match.dart`
- Related: owner decisions D2, D4, D5, D6, D7, D9 (`docs/phase4-plan.md`), ADR 0006
  (privacy projection), ADR 0011 §2 (no personal data), ADR 0012 (ids, `complete`),
  ADR 0013 (GTIN, serial and expiry), ADR 0014 (consensus), `.claude/rules/privacy.md`
  rules 1, 5, 6, 7

## Context

A medication is free text today (name, form, strength, notes). Phase 4 lets it point at a
catalog product, remember a scanned GTIN, and hold a private manual composition. Four
constraints shape the integration:

1. The app must work without the catalog (offline-first, catalog down, `PILLPAL_CATALOG_URLS`
   unset), and free text must stay authoritative.
2. Installed field-test APKs (`docs/staging.md`) push full medication state without knowing
   the new fields; an upsert must not wipe them.
3. The catalog must not learn who searches for or scans what. The catalog request stream is
   itself health-adjacent data ("someone searched insulin").
4. Relatives see medications through a privacy projection (ADR 0006); catalog references
   and the consent flag must follow it.

## Decision

### 1. Catalog is optional; references are plain optional fields

- `PILLPAL_CATALOG_URLS` (`ru=…,eu=…`) is a dart-define. Without it all catalog UI is hidden
  (CI builds rely on it). The app picks the URL of its own region only; no cross-region
  catalog access.
- The backend never calls the catalog on a request path (ADR 0011 §4).
- Free text (`name`, `form`, `strength`, `notes`) keeps its meaning everywhere: reminders,
  history, reports and relatives never depend on a catalog row.

### 2. On-device catalog cache

- A drift table `catalog_cache (kind, id, json, fetched_at)` holds cards (product,
  composition, substances, packages) of products referenced by the profile's medications,
  so the product card and hints work offline. Nothing else from the catalog is cached
  (search results are not stored).
- Refresh: a single card (`POST /v1/products/get`) when it is opened, TTL 30 days. There is
  no background batch. Entries no longer referenced by any live medication are evicted.
- **The cache reveals medications, so it follows the same lifecycle as medication rows:**
  cleared by `wipeAccountData` (sign-out, account deletion) and evicted with a sync scope
  (revoked or lost relative access, profile removed). A test asserts both, as for the
  medication tables.
- The cache is not exported to the backend and never leaves the device.

### 3. Catalog requests are unlinkable to accounts

- **No `Authorization` header and no backend `X-Device-ID`.** The catalog rejects an
  `Authorization` header (ADR 0011 §2), so a client bug cannot leak a backend token.
- A **catalog-only install id** (`X-Catalog-Install`): a random UUID generated on first use,
  stored in the app's preferences (not `flutter_secure_storage`: it identifies nothing and
  is not a credential), regenerated on sign-out, on account deletion and every 30 days. It is never sent
  to the backend, and the backend id is never sent to the catalog. The catalog uses it only
  inside a salted, short-TTL rate-limit key and never stores it.
- **All lookups are `POST` with JSON bodies** (`/v1/search`, `/v1/gtins/lookup`,
  `/v1/products/get`), so search strings, GTINs and product ids never appear in URLs,
  proxy logs or browser-style caches. `GET` is used only for `/v1/sources` and health.
- **No IP and no query logging** on the catalog or its proxy: access logs carry route
  template, status, latency and request id (ADR 0011 §2); the Caddy `log` directive is
  absent or uses a format without URI and remote address; PostgreSQL parameter logging is
  off. The catalog is reached by the app of its region only.
- Requests are made only on user action (typing in the search field, a scan, opening a
  card); no background lookups, so the stream never enumerates the user's list.
- Search is not sent while typing faster than the 300 ms debounce, needs at least two
  characters and is online-only; offline the UI says "поиск доступен онлайн".
- Residual risk, stated in the legal list: the catalog operator can see the IP at the TLS
  edge for the duration of the connection and infer timing; mitigated by not logging it and
  by the per-region deployment.

### 4. Medication fields, sync, projection and consent

New optional fields on `medications`:

| Field | Type | Meaning |
|---|---|---|
| `catalog_product_id`, `catalog_package_id`, `catalog_composition_id` | UUID | opaque catalog ids, no foreign key (other database) |
| `gtin` | 14 digits | the scanned or entered GTIN, normalized; may be a restricted number (private) |
| `gtin_link_shared` | bool, default false | the owner's per-link consent to count this `(gtin, product)` link (D2, ADR 0014); only the profile's owner can set it, a co-guardian can clear it (owner decision 2026-11-10; refused with `forbidden_field`, 403 on REST) |
| `gtin_link_consent_version`, `gtin_link_consented_at` | int, timestamp | consent record; the timestamp is server-set, the version is **write-only** (never returned); both cleared with the flag |
| `manual_ingredients` | list ≤ 10 of `{substance_id?, name ≤ 100, strength_text ≤ 50}` | private manual composition |

- **Keep-on-absent in sync push.** The server applies only the fields that are present in the
  payload (`model_fields_set`, the `ProfileData.mutable_fields` pattern): an absent field
  means "keep the stored value", an explicit `null` means "clear". Older installed APKs push
  full state without these fields and must not wipe them. The current app always sends an
  explicit value. LWW stays per entity by `client_updated_at` (tie-break device id); a stale
  push is still rejected as a whole. The same-state/idempotency check compares only present
  fields.
- **Privacy projection.** `catalog_product_id`, `catalog_package_id`, `catalog_composition_id`,
  `gtin`, `manual_ingredients` are `FULL_ONLY`: `shared` medications expose them to
  relatives (they see the product card); `anonymous` redacted rows drop them (time and
  status only); `hidden` is invisible. `gtin_link_shared` and the consent record are **`NEVER_PROJECTED`**: the
  owner's contribution consent is not the relatives' business. The field-classification test
  fails when a new field is unclassified.
- **Consent follows the pair.** The server resets `gtin_link_shared` and the consent record whenever `gtin` or `catalog_product_id` changes, unless the same upsert is from a full-access role and sets it true; editors may re-link but never carry consent. The app resets it on any re-link (including §6) and re-offers the checkbox. The app sends `gtin_link_shared` only for full-access scopes. CHECK violations map to `422`.
- **A grant needs the version in the same mutation (review of 4.6).** `gtin_link_consent_version` is write-only: it is never returned, so a device holding old state cannot echo it back. A grant (consent not yet given for this pair) is valid only when a full-access upsert sends `gtin_link_shared: true` **with** a supported `gtin_link_consent_version` while `catalog_contributions_enabled` is on and the GTIN is shareable (valid check digit, not restricted: `gtin_not_shareable` otherwise); `true` without a version is not a grant (consent stays false, the rest of the write applies), an echo for an already consented pair changes nothing, `false` always withdraws. **The app sends the version only in the mutation where the user ticked the box.** A role without full access that sends either consent key is refused with `forbidden_field` whatever the stored value is, after the conflict rules. The consent is also reset when a profile passes to a co-guardian or is archived at an account deletion request.
- **Write rule.** An editor upsert that changes `gtin_link_shared` is rejected with
  `forbidden_field` (current state returned projected). Only full-access roles (owner,
  guardian) consent to contribution. Absent means unchanged, so an editor's ordinary push
  passes. Editors may change the other reference fields (they edit the medication).
- **Erasure.** Tombstones and account erasure null all fields and set `gtin_link_shared` false
  (`tombstone_erased` CHECK extended in the first migration, `NOT VALID` then `VALIDATE`; CHECK
  `deleted_at IS NULL OR NOT gtin_link_shared`). The relative PDF uses `project_medication`. The needle test asserts it. The Phase 5 export
  covers them through the existing table inventory.
- **Logging.** `gtin`, `catalog_*_id`, `manual_ingredients` and `q` join `SENSITIVE_KEYS`
  and Sentry scrubbing. They never appear in push payloads.
- **Opt-in checkbox (D2).** Shown **only at link time**: when a full-access user links a
  product to a GTIN that is shareable and unknown to the catalog, and
  `/v1/me/features.catalog_contributions_enabled` is true. Default **off**. It is never
  pre-checked, never shown for restricted GTINs, for editors, or when merely viewing.
  Wording (RU / EN, versioned with the consent record of Phase 5; final text after legal
  review, plan item 5):
  - label: «Анонимно помочь другим распознавать эту упаковку» / "Anonymously help others
    recognize this package";
  - explanation under it: «Мы передадим только число подтверждений для пары „штрихкод —
    продукт“. Ваше имя, профиль и лекарства не передаются. Отключить можно в карточке
    лекарства» / "Only a count of confirmations for the pair 'barcode — product' is shared.
    Your name, profile and medications are not. You can switch this off on the medication
    card".
  Switching it off, unlinking, deleting the medication or deleting the account lowers the
  count at the next snapshot (ADR 0014 §2–§3).
- **Scan privacy.** The GS1/Честный знак parse runs on the device; only the GTIN-14 can be
  sent, only for shareable numbers and only to `/v1/gtins/lookup`. Serial and lot are
  discarded in the parser (ADR 0013 §4). The expiry date (AI 17) is parsed for validation and
  **not stored** anywhere (D7): no column, no local field, no log. No image is captured or
  stored.

### 5. Selecting a product: fill empty only, foreign market labelled

- Choosing a catalog product sets the references and **fills only empty free-text fields**
  (name, form, strength) from the card (D5). For every field that already has text the form
  shows an explicit «заменить» offer with the catalog value; nothing is overwritten silently
  and declining keeps the text. "Отвязать" clears the references and keeps all text.
- Search results show own-market products first and foreign-market ones after them, each
  with its `country` as a label (D6, ADR 0012 §5). The user may link any market.
- Catalog data may be incomplete or wrong; the product card carries the note «данные
  справочника могут быть неполными», the source attribution and a "withdrawn" label for
  withdrawn rows. A withdrawn product stays linked.

### 6. Same composition, link to existing and overlap hint

All matching is computed **on the device** in `pillpal_core`
(`composition_match.dart`, pure Dart) from the cached cards of the same profile's live
medications. Nothing is sent to the server to compute a hint. There is **no analog list or
analog hint** (owner decision D9).

- **Same composition** means equal `catalog_composition_id` and `complete = true` (ADR 0012
  §1). Incomplete compositions (EMA, sources without structured strengths) never trigger it.
  Compositions of different sources are different rows, so it never bridges markets.
- **Link to existing (D4).** When the chosen product's composition equals that of an existing
  medication X in the same profile, the app asks: «Это тот же состав, что «X». Привязать
  упаковку к нему?» with «Привязать» | «Создать отдельно». Linking **replaces** X's
  `catalog_package_id`, `catalog_product_id` and `gtin` (and `catalog_composition_id` if it
  was empty) and **keeps** X's name, free text, schedules, stock and history; no new
  medication is created. "Create separately" is always available and never blocked.
- **Overlap hint.** When the candidate shares a **catalog substance id** with a medication of
  the same profile (including `manual_ingredients[].substance_id`), a neutral note is shown.
  Free text is never used for overlap, to avoid false hints. Different profiles are never
  compared.
- **Wording is neutral and informational** (RU / EN golden strings in tests): «Оба содержат:
  {вещества}» / "Both contain: {substances}". An info icon, no warning colour, no words such
  as "опасно", "не принимайте", "риск", "дублирование" and no advice to stop, change or combine
  anything. Dismissible, never blocks saving, never produces a notification or a push, never
  shown to relatives, no ads on these screens (privacy rule 8).
- The medical-device classification risk of hints and prompts is a legal item (plan, Legal
  review 6); the wording above is the mitigation.

## Consequences

- Backend: migrations `0014_medication_catalog_refs`, `0015_med_manual_ingredients`;
  keep-on-absent in `MedicationData`; the sync-protocol change is flagged in the PR body.
- App: drift v7, DTOs, `data/catalog/*`; the catalog client is a separate `Dio`/`http`
  client with no interceptors from `ApiClient` (a test asserts no `Authorization` and no
  device id).
- Old APKs keep working and ignore unknown pulled keys (asserted in 4.6).
- The cache adds a second place where medication-related data lives on the device; its
  wipe is part of every wipe path.
- The "link to existing" action changes an existing medication from a catalog event; it is
  an ordinary LWW edit of that medication, so it syncs and converges like any edit.
- Counting confirmations requires the user's choice every time; contribution volume will be
  low, and promotion slow, by design (ADR 0014).

## Alternatives considered

- **A dedicated `medication_catalog_links` table** instead of columns: more joins and a
  second sync entity for six scalar fields; rejected.
- **Authenticated catalog calls** (better abuse control): ties the stream to accounts;
  rejected.
- **Fetching cards through the regional backend** as a proxy: removes the IP from the
  catalog but puts every search into the backend's logs and request path; rejected for
  Phase 4, may be revisited with an OHTTP relay.
- **`GET` lookups with the query in the URL**: leaks into proxy logs; rejected.
- **An analog list / analog hint** (D9): a recommendation-like feature with medical-device risk; rejected.
- **Server-side overlap computation**: would send medication lists to a service;
  rejected.
- **Overwriting typed text on product selection**: loses user edits; rejected (D5).
- **Opt-out or once-per-account consent** for contribution: rejected (D2, ADR 0014).
- **Caching search results on the device**: unbounded, reveals past interest; rejected.
