# ADR 0016 — Consent records and data export (Phase 5)

- Status: Accepted (owner decisions 2026-11-10); amended 2026-11-10 after the privacy and
  security review (see the Review log in `docs/phase5-plan.md`)
- Date: 2026-11-10
- Scope: TZ §2.6 ("Удаление аккаунта и экспорт данных"), §5 "Фаза 5" ("согласие на обработку
  медданных отдельным документом"), §3; backend migrations `0017_consents`, `0021_data_exports`;
  `app/settings_consent.py`, `app/settings_export.py`; services `consents`, `consent_ledger`,
  `export_archive`, `data_export`; router `me_privacy`; `POST /v1/auth/register`; ARQ cron
  `build_data_exports`; `personal_data.py`, `erasure.py`, `account_deletion.py`; app A1
- Related: owner decisions Q3, Q4, Q5, Q6 (`docs/phase5-plan.md`), ADR 0010 (deletion grace and
  restore), ADR 0014 §2 and ADR 0015 §4 (per-link contribution consent), ADR 0017 (OAuth step-up,
  §8), `docs/spec/export.md` (archive v1), `.claude/rules/privacy.md` rules 1, 3, 6, 7

## Context

The stores and both laws need two things PillPal does not have yet. First, explicit,
separate consent to process health data, stored with version and timestamp (privacy rule 6,
152-FZ art. 9 and art. 10, GDPR art. 9(2)(a)). Second, a way for users to get their own data
(GDPR art. 15 and art. 20; TZ §2.6). Phase 4 already keeps a per-medication contribution
consent (`gtin_link_shared`, version write-only, ADR 0015 §4). Strict environments refuse
`CATALOG_CONTRIBUTIONS_ENABLED=true` until a consent ledger exists.

Constraints:
- Field-test APKs register without sending consents; they must keep working until the app
  ships the consent screen (A1).
- The server is a sync peer and must never stop reminders. A missing consent must not make
  sync fail on the server.
- An export is the most concentrated medical artefact the system produces. It must not reach
  logs, URLs, e-mail or another device, and must not outlive its purpose.
- New tables are not sync entities: they use server-generated ids and never appear in
  `/v1/sync/*`.

## Decision

### 1. Consent kinds, versions and sources

Table `consents (id, user_id fk CASCADE, kind, version, source, accepted_at, withdrawn_at null)`:

| Column | Constraint |
|---|---|
| `kind` | CHECK IN (`health_data`, `terms`, `privacy`, `catalog_contribution`) |
| `version` | int, CHECK `1..MAX` |
| `source` | CHECK IN (`registration`, `in_app`, `oauth_signup`, `medication_link`) |
| `withdrawn_at` | CHECK `withdrawn_at >= accepted_at` |

- Partial UNIQUE `(user_id, kind, version) WHERE withdrawn_at IS NULL` (one active record per
  version), index `(user_id, kind)`. Rows are append-only facts: accepting again inserts a
  new row and never rewrites an earlier one. `withdrawn_at` is the only mutable column.
- Versions come from settings, **per region** (each deployment has its own values):
  `CONSENT_VERSIONS_{HEALTH_DATA,TERMS,PRIVACY}=[1]`. A version covers all locales of that
  text; a translation never needs a new version. `catalog_contribution` reuses
  `GTIN_LINK_CONSENT_VERSIONS` (ADR 0015 §4), so the medication field and the ledger cannot
  disagree. The current version of a kind is the last entry of its list. Texts are versioned
  placeholders until legal review. A text change means a new version, never an edited one.
- `accepted_at` is set by the server. The client sends only `{kind, version}`.

### 2. API

- `GET /v1/me/consents` returns `{current, records, missing}`. `missing` lists the required
  kinds (`health_data`, `terms`, `privacy`) that have no active record of the current version.
- `POST /v1/me/consents {kind, version}` (source `in_app`, rate-limited):
  - 201 on a new record; replaying an active record returns 200;
  - a non-current version is 422;
  - `catalog_contribution` is 422, because that kind is recorded only through a medication
    link (§4).
- `FeaturesOut.consent_required_kinds` tells the app which kinds it must collect.

### 3. Registration: optional in field-test builds, required in prod

- `POST /v1/auth/register` gains an optional `consents: [{kind, version}]` (max 4, unique kinds).
  Validation:
  - when the field is present, or `CONSENT_REQUIRED_AT_REGISTRATION=true`, it must contain the
    current `health_data`, `terms` and `privacy` versions. Otherwise 422 `consent_required`;
    an unknown version is 422 `unsupported_consent_version`;
  - validation does not depend on whether the e-mail exists. A known address records nothing
    and gets the same 202 (no enumeration, ADR 0010 §3);
  - a new account records the consents with source `registration`. OAuth sign-up (ADR 0017)
    uses `oauth_signup`.
- `ENVIRONMENT=prod` forces `CONSENT_REQUIRED_AT_REGISTRATION=true` from its first deployment
  (a settings validator refuses `false` in prod). The optional window exists only on dev and
  staging field-test builds: `CONSENT_REQUIRED_AT_REGISTRATION=false` there until milestone
  5.11, which flips the staging default once A1 has shipped to staging. Old field-test APKs
  keep registering on dev and staging until then.
  *As built (5.11, 2026-11-11):* staging defaults to `true` when unset; an explicit `false`
  (passed by the staging compose from `.env`) is still accepted there for an old field-test build.

### 4. Withdrawal and deletion

- `health_data`, `terms`, `privacy`: `POST /v1/me/consents/withdraw` answers 409
  `withdraw_via_account_deletion`. Withdrawing consent to the processing the service is built
  on is an account deletion request (ADR 0010 §1): relatives, detection and push stop at the
  request, and data is erased within the grace period. The app opens the deletion dialog.
- **Deletion stamps withdrawal.** A deletion request sets `withdrawn_at = now` on every active
  `health_data`, `terms` and `privacy` record in the same transaction. A restore (ADR 0010)
  therefore leaves `missing` non-empty, and the §5 gate runs before any medical sync. Implemented
  in 5.2a.
- `catalog_contribution` (milestone 5.2b; 501 until then):
  - **Ledger.** A full-access write that sets `gtin_link_shared=true` with version V inserts an
    active `catalog_contribution` / `medication_link` row in the same transaction, if none
    exists for V. It adds no journal entry. Editors never record a consent (ADR 0015 §4), and
    replaying a push is idempotent.
  - **Owner only** (owner decision 2026-11-10). Only the profile's owner can set
    `gtin_link_shared=true`; a co-guardian's grant is refused with `forbidden_field` (403 on REST),
    while clearing and echoing an existing grant stay allowed. The ledger user is therefore always
    the profile owner, and withdrawal and deletion, which reset the links of the profiles the
    user owns, are exact. A stale offline grant (`client_updated_at` not after the user's latest
    withdrawal) is not a grant: the link stays reset and the rest of the write applies.
  - **Published links stay.** A link already promoted into the catalog consensus stays there
    (ADR 0014 §4, sticky promotion); withdrawal only removes the person from future snapshots.
    Links granted before 5.2b have no ledger row (no backfill; staging and prod never allowed
    contributions).
  - **Withdraw.** Runs under the user's journal lock: sets `withdrawn_at` and calls the
    journaled `reset_consent_in_profiles` for the profiles the user owns. Other devices see the
    reset links in their next pull. Response 200 `{reset_links: n}`; a replay returns n = 0.
    Re-ticking a link afterwards inserts a new record (ADR 0014 §2–§3 lower the count).
  - The strict-environment refusal of `CATALOG_CONTRIBUTIONS_ENABLED` stays after 5.2b, until
    the final legal texts exist (Q5); lifting it is a one-line PR.

### 5. Re-consent gate for existing accounts (Q3)

Accounts created before consents existed, before a version bump, or restored after a deletion
request (§4) have a non-empty `missing`. On its next launch the app shows a blocking consent
screen until the kinds are recorded through `POST /v1/me/consents`.

- While `missing` contains `health_data`, the app (A1) does not push or pull medical entities
  (medications, schedules, dose events). Local reminders keep firing from local data. Sync
  resumes after `POST /v1/me/consents` succeeds for the missing kinds.
- The server refuses nothing from the owner for missing consent: no sync and no other request
  of theirs is rejected for it. What it does for relatives, detection and push is in "As built
  (server pause)" below.
- Processing of already-held data during the gate is a legal item (§10).

**As built (A1b, app).**
- **What pauses.** The sync pauses only when `health_data` is in `missing` **and** `records` holds
  no active (non-withdrawn) `health_data` record of any version: never recorded, or withdrawn
  (a deletion request, then a restore). When only the version is outdated (an active older
  record), the gate screen is still shown and asks for the new text, but sync continues and the
  paused notice is not shown (owner decision 2026-11-11). The device stores this in the one
  `consent_missing` column: an item `~health_data` means "outdated only" and does not pause.
- **Whole-run pause.** While the sync is paused, the sync engine ends a run with
  the local code `consent_paused` (distinct from the server's `consent_required`; status idle,
  not an error) right after the eviction of stale foreign
  scopes and before the first request. Push, pull and the REST reads of the reconcile step are
  all paused. Filtering by entity was rejected: the outbox is ordered across entities, so
  skipping rows would break `seq` order, and a pull page mixes entities of one scope.
  When only `terms` or `privacy` are missing the sync runs and the gate is still shown.
- **Nothing changes while paused.** Outbox rows keep `seq`, `client_updated_at`, `attempts`
  and `parked`; cursors do not move. On resume the whole outbox is pushed in `seq` order, then
  the pull continues from the old cursors; LWW and `410 cursor_expired` behave as usual.
  Account deletion and sign-out from the gate still work. Signing out **keeps the data** bound
  to the account (the forced-sign-out path): the paused rows are sent after the same account
  signs in again and consents. A second, destructive choice ("Sign out and erase data from this
  device") wipes the device after a warning about the unsent changes. There is no "sync first"
  choice, because it could not send anything.
- **Stored answer.** Schema 8 adds `SyncState.consent_missing` (null = not asked, empty =
  nothing missing, else the missing kinds). It is reset by the binding itself on every sign-in
  (verify, login, restore; not on a token refresh), atomically with gaining the tokens, and
  with the account data. It is written only while the data is bound to the account that asked.
  **Every run asks `GET /v1/me/consents` and stores the answer**; the stored one is used only
  when the server cannot be reached (nothing would be sent anyway), and with none the run fails
  with the network error. A stale answer therefore never decides while the network is up. The
  background isolate (notification-action flush, WorkManager) uses the same gate; its outcome is
  `paused` and is not retried. The app also refreshes the answer at start and on resume.
- **Refusals in a foreign scope.** A push refused with `not_found` or `parent_not_found` in
  someone else's scope evicts the whole scope (cursor included) instead of the entity; if the
  account still has access, the pull of the same run lists it again and fetches it from 0, so a
  resumed relative never keeps a stale cursor that silently misses entities.
- **Resume.** After the texts are recorded the app asks the engine to rerun right after the run
  in progress (`rerunAfterCurrent`), so a run that had already decided to pause cannot swallow
  the request. The health data text is recorded first, so a later failure does not keep the
  sync paused.
- **While the gate is closed the server is blind.** Taken marks and changes made on this device
  do not reach the server, so the missed-dose detector sees no `taken` events and relatives see
  nothing new; a missed-dose alert may be wrong. The server pause below makes the detector and the
  relative-facing paths skip such profiles.
- **Deployment order.** The backend with `/v1/me/consents` (5.2a) must be deployed before the
  app update: against an older server `GET /v1/me/consents` is a 404, which the engine reports
  as a failed run (the app cannot learn the answer).
- **Reminders** never read it: they run from the local database, and "Taken" in the shade
  writes the dose event and its outbox row without a request.
- **Gate screen.** `/consent` shows only the missing texts (the B2-Consent boards, adapted),
  with "Continue", "Sign out" and "Delete account". Every other location, deep links and
  push taps included, redirects to it. The texts are recorded one after another; after a
  partial failure only the rest is asked again. A `422` (or a kind the app has no text for)
  means the server is ahead of the app: the screen blocks with "Update the app" and keeps its
  exits.

<!-- BEGIN As built (server pause) -->
#### As built (server pause)

Implemented in `fix/server-consent-pause`, following the app's gate (this section's first bullet).
Without it the server would keep detecting "missed" doses for an account whose app is not syncing
and would keep processing health data without consent.

- **Owner decision A (2026-11-11): only a missing consent pauses.** A profile's owner is unconsented
  when they have no active (not withdrawn) `health_data` record of *any* version: never recorded or
  withdrawn. A new text version ("outdated") is a client gate only; processing continues under the
  previous consent until the user accepts. The rule does not read `CONSENT_REQUIRED_AT_REGISTRATION`:
  accounts created while the flag is off have no records and are paused too, so field-test accounts
  are paused once the app's gate ships and resume when they accept in the app. `terms` and `privacy`
  alone never pause. Consent records are **never backfilled** (an inserted record is a consent nobody
  gave).
- **Owner decision B (2026-11-11): any full-access guardian is enough.** A profile is not paused
  while its owner, or any holder of a guardian grant (not pending deletion), has an active record. A
  consenting co-guardian keeps scope, REST, reminder data and missed-dose alerts of a managed
  profile, and so do its viewers and editors. The guardian test reads `profile_grants` directly, so
  grant activity does not depend on itself.
- **Switch and deployment order.** `CONSENT_SERVER_PAUSE_ENABLED` (default true); false pauses
  nothing. The backend and the app with the A1b gate are deployed together; field testers accept in
  the app (`docs/staging.md`).
- **Query time, no migration.** `app/services/consent_pause.py`: `profile_consented()`, an `EXISTS`
  on `consents` (partial unique index `uq_consents_active`) for the owner or a guardian. Nothing is
  stored, so a re-accepted consent resumes everything at the next read.
- **Detector.** A paused profile is not eligible: no alert, no push, no resolved notice; the window
  moves on, so the span is not made up later. The tick whose window contains the consent's
  `accepted_at` is skipped as well (no false alert right after resume). Queued `missed` pushes of a
  paused profile are dropped at the claim step (`access_changed`), the owner's included; `resolved`
  is not held back.
- **Relatives.** A grant on a paused profile is *inactive*, exactly as for a pending deletion
  (`grant_is_active`; archives are exempt, ADR 0010 D1). Chosen over "empty scope with a flag"
  because the one predicate every relative-facing path already shares covers them all, needs no new
  client state and makes the relative's app evict its copy: the pull omits the scope and lists it in
  `revoked`; REST reads by a guardian are 404; pushes of editors and guardians are
  `rejected/parent_not_found`; `GET /v1/grants` shows `active: false` to the owner and hides the
  grant from the relative; a grantee's `PATCH` is 404 while `DELETE` stays 204, so leaving is always
  possible; accepting an invite into a paused profile is `invite_invalid`. When consent returns the
  scope reappears and the client pulls it from 0 (no `granted_seq` change, as after a restore).
  A future PDF or share endpoint for relatives must use `grant_is_active`.
- **Limits and catalog.** `count_relatives` and the scope limit count every grant, paused or not.
  The next contribution snapshot excludes a paused profile's links.
- **Accepted losses** (rare once the field test has consented): a relative's unsent writes on a
  scope that is evicted are dropped, not parked, and the device-local reminder settings of an
  evicted scope reset. `link_*` notices follow their grant and are dropped while it is inactive.
- **Accepted edge case.** For a managed profile the owner's app may be paused while a consenting
  co-guardian keeps the profile unpaused on the server. The detector then runs, and Taken marks
  stuck on the owner's device can produce false missed alerts to the co-guardian.
- **Client eviction.** The app's foreign-scope eviction on a push refusal (A1b, above) also drops
  that device's other outbox rows for the scope.
- **Still open.** Section 10 point 4 stays open for the owner's own sync and for data held while
  the gate is open: the server refuses nothing from the owner.
<!-- END As built (server pause) -->

### 6. Erasure of consent records (Q4)

`consents` is personal data, exported as rows and erased with the account (FK CASCADE plus the
erasure inventory). No proof of consent is kept after the hard erase until legal review asks
for one. Keeping a proof would need its own retention basis and an ADR amendment.

### 7. Export format, contents and consistency

- Archive format v1 as specified in `docs/spec/export.md`:
  - a zip with `manifest.json` (`format_version`, `region`, `generated_at`, row counts), then
    `tables/<table>.json` in alphabetical order;
  - fixed member metadata, deterministic for the same input;
  - a removed or renamed column needs a new `format_version`.
- Contents follow `TABLE_CLASSIFICATION`. Every non-system table carries an `export` decision
  (`rows`, or `none` with a reason). Credential columns are excluded (`password_hash`,
  `token_hash`, `push_tokens.token`, `*_enc`). Other accounts appear only as opaque ids.
  The account's own `hidden` and `anonymous` medications are included.
- `auth_identities.subject` **is exported**: it is the account holder's own provider id
  (GDPR art. 15), even though the API never returns it (ADR 0017 §2).
- `admin_audit.actor` and the operator columns (ADR 0018 §5) are **excluded**: they describe
  operators, not the account holder.
- Decisions made when each table is created: `consents`, `entitlements`, `promo_redemptions`,
  `auth_identities`, `purchases`, `admin_audit` (rows about the user, actor excluded) are
  exported; `data_exports` is medical with export `none` (§8); `promo_codes` is `system`.
- **Snapshot isolation.** `collect_account_data` reads every table in one `REPEATABLE READ`,
  read-only transaction, so there are no orphan rows between tables. `build_archive` is pure
  and runs in `to_thread`.

### 8. Export transport (Q6)

Table `data_exports (id, user_id fk CASCADE, family_id uuid, status, error_code, requested_at,
lease_until, ready_at, expires_at, size_bytes, archive bytea null)`:
- status CHECK IN (`queued`, `running`, `ready`, `downloaded`, `failed`, `expired`), and
  CHECK `archive IS NULL OR status = 'ready'`;
- `error_code` CHECK `IS NULL OR IN ('export_too_large', 'export_build_failed')`;
- classified `medical`, export `none`, erased with the account;
- a deletion request deletes the account's exports in the same transaction.

**Session binding.** The access JWT gains a `sid` claim holding the refresh-token `family_id`
(ADR 0017 §8 uses the same re-auth). `family_id` is the session the export belongs to. Access
tokens without `sid` (issued before this change) cannot download; the app signs in again.

Flow, behind `FEATURE_DATA_EXPORT=false` (`FeaturesOut.data_export_enabled`):
- **Request.** `POST /v1/me/export` requires step-up re-auth: body `{password}` or
  `{reauth: {provider, platform, assertion}}`, the same schema and rules as `DELETE /v1/me`
  (ADR 0017 §8). A failed re-auth returns the same errors as `DELETE /v1/me`. On success it
  returns 202 with the export id and stores the request's `family_id`.
  - Replaying while an export is active → 200 with the same export. A replay sends no notice.
  - A new request mails a notice to the account address: "an export was requested". The notice
    carries no data and no link.
  - **Cooldown.** A new request within `EXPORT_COOLDOWN_SECONDS=3600` of an export that is not
    `downloaded` → 429 `export_rate_limited`. Rows in `downloaded` status do not count, so the
    user can request again at once after a download.
  - Flag off → 403.
  - The password is a **required** body field, so a missing proof is 422 exactly like
    `DELETE /v1/me`; the OAuth form (`{reauth: {...}}`, ADR 0017 §8) joined it in 5.7. Password attempts count in the login
    bucket, the step-up scopes fail closed when Redis is down, and the session (refresh
    family) must be live and unexpired.
  - The cooldown ignores `failed` and `downloaded` rows; `downloaded` rows count toward
    `EXPORT_MAX_PER_DAY`.
- **Job.** ARQ cron `build_data_exports` runs every minute and takes no arguments:
  - claims `queued` or lease-expired rows with `FOR UPDATE SKIP LOCKED`, so a crashed worker's
    row is picked up again;
  - builds, checks `EXPORT_MAX_BYTES` (64 MiB; over the cap the export fails with
    `export_too_large`) and encrypts (§9);
  - skips accounts pending deletion;
  - in the same cron, nulls the archive and marks the row `expired` once past `expires_at`
    (`EXPORT_TTL_HOURS=24`), and deletes metadata rows after `EXPORT_RETENTION_DAYS=7`.
- **Status.** `GET /v1/me/export/{id}`; a foreign id is 404. Per-user rate limits apply.
- **Download.** `POST /v1/me/export/{id}/download`:
  - the bearer must be the same account **and** its `sid` must equal the row's `family_id`.
    A mismatch is 404, so the archive cannot reach another session of the same account;
  - the claim is one atomic statement:
    `UPDATE data_exports AS d SET status='downloaded', archive=NULL FROM (SELECT x.id, x.archive
    FROM data_exports x WHERE x.id = :id AND x.user_id = :uid AND x.family_id = :sid AND
    x.status='ready' AND x.expires_at > :now AND <the session's refresh family is not revoked>
    FOR UPDATE OF x) AS old WHERE d.id = old.id RETURNING old.archive, d.ready_at`
    (a bare `SET archive=NULL ... RETURNING archive` would return the new, NULL value).
    No row → 404, 409 or 410 as the row's state says. Two concurrent downloads cannot both win;
  - 200 returns the zip with `Cache-Control: no-store` and
    `Content-Disposition: attachment; filename="pillpal-export-<region>-<YYYYMMDD>.zip"`
    (`<YYYYMMDD>` is the UTC date of `ready_at`);
  - the claim commits before the bytes are sent. A transfer that fails after the commit loses
    the export; the user requests a new one (§8 cooldown rules apply);
  - 409 `export_not_ready` / `export_failed`, 410 `export_gone` after download or expiry.
- **POST, not GET,** so the response is never cached or replayed from history. The id in the
  path is an opaque UUID that grants nothing without the bearer token and the matching `sid`.
  The archive is never e-mailed and never pushed. A notification "export ready" is not in this
  slice.
- On the device (A1) the file goes to app-private storage excluded from backups, is offered
  to the share sheet, and is deleted when the export screen is left (see the A1c note: not at
  the moment of sharing, because the target may still be reading it).

**As built (A1c, app).** «Приватность и данные» (`/settings/privacy`) and the export screen
(`/settings/privacy/export`).
- **Consents list.** `GET /v1/me/consents` on opening, not stored. Each baseline kind shows its
  newest active record (date and version) or "Not given". The health data switch never calls
  `POST /v1/me/consents/withdraw` (it answers 409): it opens the account deletion dialog with a
  lead sentence saying that withdrawing this consent is a deletion request. The catalog
  contribution row exists only while a record of it is active; "Withdraw" asks, posts
  `{kind: catalog_contribution}`, shows the number of reset links and asks for a sync, so this
  device pulls the reset links.
- **Export availability.** The row shows when `FeaturesOut.data_export_enabled` is true and the
  account has a password (the app has no OAuth sign-in yet, so the step-up is the password only).
  Unknown features (offline) mean off. The texts say "JSON archive, once, within 24 hours"; the
  archive holds no PDF and is never e-mailed.
- **Download.** `ApiClient.downloadTo` is a `POST` that streams the body into a file, never into
  memory, under a size cap (the server's 64 MiB plus a 1 MiB margin) and an idle timeout (the
  request timeout between two chunks). A `401` refreshes the session and retries **once**, which
  is safe because auth fails before the claim. Everything after the response headers is a single
  attempt: a broken transfer, a stall, a cap breach or a short body deletes the partial file and
  is not repeated. After a transfer failure the controller asks the status once: `ready` offers
  "Check again", anything else says the archive is lost and a new export must be requested
  (the cooldown ignores `downloaded` rows, so that works at once).
- **The file.** `getTemporaryDirectory()/exports/pillpal-export-<region>-<YYYYMMDD>.zip`, one at
  a time. It is **not** deleted at the moment of sharing: the share sheet reports success when a
  target is picked, and a target may still be reading the file. It is deleted when the export
  screen is left (a closed share sheet included, owner decision 2026-11-11), when the app comes
  back to the foreground after a share, on any failure, at app start, and on sign-out or an
  account switch, together with the `share_plus` copy. The screen cannot be left during the
  download. Its path, id and content are never logged (a static test guards the code that
  handles them); errors carry codes only.
- **Failures.** Any unexpected error ends the flow in `failed` with the partial files deleted,
  never in a spinner. The download is a bounded stream: byte cap, idle timeout and an overall
  deadline, with backpressure; the body of a refused download is read up to 64 KiB.

### 9. Encryption at rest

- **Keyring.** `DATA_ENCRYPTION_KEYS={id: base64}` holds the keys and `DATA_ENCRYPTION_KEY_ID`
  names the key used for new writes. Each key is 32 random bytes, base64-encoded. Startup
  decodes each key and refuses any that is not 32 bytes. No key may equal `JWT_SECRET` or
  `PROMO_CODE_HMAC_KEY`. Strict environments refuse the export flag without the keyring.
- **Blob.** `key_id (1 byte) || nonce (12 bytes) || ciphertext || tag`, AES-256-GCM, random
  nonce per encryption.
- **Per-row key.** `HKDF-SHA256(ikm = keyring key, salt = row id, info = purpose)`, with
  purpose `pillpal-export/v1` for exports and `pillpal-oauth-refresh/v1` for Apple refresh
  tokens (ADR 0017 §9). The row id is the export id or the identity id. A leaked blob plus
  another row's key decrypts nothing.
- **AAD** = `key_id || purpose || row_id`. A blob cannot be moved to another row or purpose.
- **Rotation.** Add a new key to the keyring, point `DATA_ENCRYPTION_KEY_ID` at it, and
  re-encrypt old blobs with the current key (a job, or on access). Decrypt uses the key named by
  the blob's prefix. A key is removed from the keyring only when no row references it.
- The keyring lives in the regional environment only. Archives never leave the region except
  as the user's own download.
- `PROMO_CODE_HMAC_KEY` follows the same rule: 32 random bytes, base64, decoded and
  length-checked at startup (ADR 0018 §3).

### 10. Needs legal confirmation

1. Consent texts and versions (placeholders now). Whether one combined `terms`/`privacy`
   screen with a separate health-data checkbox satisfies "отдельным документом" (TZ §5).
2. Withdrawal of health-data consent implemented as a deletion request with up to 30 days of
   blocked storage (ADR 0010 §4).
3. Erasing consent records with the account, with no retained proof (Q4).
4. Continued processing for existing accounts while the re-consent gate is open (Q3).
5. The export exclusions and the D1 heir rule of `docs/spec/export.md`.
6. A 1-hour cooldown and a 24-hour single download as adequate access for GDPR art. 15/20 and
   152-FZ art. 14. Export import for a region change is a later follow-up (Q6).
7. 152-FZ art. 9(1): whether a separate consent document is needed for health data, and whether
   the in-app tick meets the written-form equivalence of art. 9(4) and art. 10 through a simple
   electronic signature (63-FZ).
8. Consent for managed profiles: a child's profile needs the legal representative's consent;
   an adult managed profile needs its own legal basis.
9. EU to US transfers to Apple and Google for sign-in and purchases (DPF or SCC).
10. Retention of purchase records against the accounting duty, when an account is erased.
11. GDPR art. 15 supplementary information in the export notice, and the 152-FZ art. 14
    answer within 10 working days.

## Consequences

Positive:
- Consent is provable per kind and version, and both the registration path and the in-app
  path write the same ledger.
- Contribution withdrawal reuses the journaled reset, so it converges on every device without
  a sync-protocol change.
- An export is consistent, deterministic, encrypted in its region, readable once by one
  session, and gone within 24 hours.

Negative:
- `bytea` archives live in PostgreSQL, up to 64 MiB each, for at most 24 hours. Backups taken
  in that window contain encrypted exports, so the staging `backup.sh` dumps with
  `--exclude-table-data=data_exports`, and the prod backup gate below must do the same.
- **Known limit: memory.** The archive is built and encrypted in memory (up to
  `EXPORT_MAX_BYTES`, 64 MiB). Streaming or chunked AEAD is required before the cap is raised.
- **Backups are an open pre-prod gate.** Before the first prod deployment, either backups
  expire within the deletion grace period minus the time already used, or a restore excludes
  erased accounts (ADR 0010 §4). Not decided yet. Either way, exclude the data of
  `data_exports` from backups.
- The 409 on health-data withdrawal is a deliberate dead end in the API; the app must route
  users to deletion.
- A transfer that fails after the claim loses the export by design (§8).
- Until 5.11, dev and staging accounts can still be created without consent records. Prod
  cannot (§3). The gate (§5) catches them at the next launch.

Follow-ups:
- 5.2a, 5.2b, 5.5, A1, 5.11.
- Backup retention decision before the first prod deployment (see Negative).
- Export import for a region change.

## Alternatives considered

- **A boolean `consented_at` on `users`.** No kind, version or history, and no trace of
  withdrawal; rejected.
- **Allow withdrawing health-data consent while keeping the account.** The server would hold
  medical data it may no longer process, and every service would need a "consent withdrawn"
  mode; rejected in favour of the deletion path (ADR 0010).
- **Refuse sync for accounts without consent.** It would stop relatives' views and
  missed-dose detection and could look like the app broke; reminders are local anyway.
  Rejected (Q3).
- **Synchronous export in the request.** Unbounded latency and memory on the API process;
  rejected for an ARQ job.
- **Signed download URL or e-mailed link.** Bearer capabilities in URLs and mailboxes;
  rejected.
- **Object storage for archives.** A new datastore (needs an ADR) for a 24-hour artefact;
  rejected while the 64 MiB cap holds.
- **One key for everything (`JWT_SECRET`).** Couples token signing with data encryption;
  rejected.
- **Bind the download to the device id (`X-Device-ID`).** The header is client-supplied and
  not a session credential; the refresh-token family is the server's own session and is in the
  access token; rejected.
