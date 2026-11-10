# ADR 0016 — Consent records and data export (Phase 5)

- Status: Accepted (owner decisions 2026-11-10)
- Date: 2026-11-10
- Scope: TZ §2.6 ("Удаление аккаунта и экспорт данных"), §5 "Фаза 5" ("согласие на обработку
  медданных отдельным документом"), §3; backend migrations `0017_consents`, `0021_data_exports`;
  `app/settings_consent.py`, `app/settings_export.py`; services `consents`, `consent_ledger`,
  `export_archive`, `data_export`; router `me_privacy`; `POST /v1/auth/register`; ARQ cron
  `build_data_exports`; `personal_data.py`, `erasure.py`, `account_deletion.py`; app A1
- Related: owner decisions Q3, Q4, Q5, Q6 (`docs/phase5-plan.md`), ADR 0010 (deletion grace and
  restore), ADR 0014 §2 and ADR 0015 §4 (per-link contribution consent), `docs/spec/export.md`
  (archive v1), `.claude/rules/privacy.md` rules 1, 3, 6, 7

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
  sync fail.
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
- Versions come from settings: `CONSENT_VERSIONS_{HEALTH_DATA,TERMS,PRIVACY}=[1]`.
  `catalog_contribution` reuses `GTIN_LINK_CONSENT_VERSIONS` (ADR 0015 §4), so the medication
  field and the ledger cannot disagree. The current version of a kind is the last entry of
  its list. Texts are versioned placeholders until legal review. A text change means a new
  version, never an edited one.
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

### 3. Registration: optional now, required in 5.11

- `POST /v1/auth/register` gains an optional `consents: [{kind, version}]` (max 4, unique kinds).
  Validation:
  - when the field is present, or `CONSENT_REQUIRED_AT_REGISTRATION=true`, it must contain the
    current `health_data`, `terms` and `privacy` versions. Otherwise 422 `consent_required`;
    an unknown version is 422 `unsupported_consent_version`;
  - validation does not depend on whether the e-mail exists. A known address records nothing
    and gets the same 202 (no enumeration, ADR 0010 §3);
  - a new account records the consents with source `registration`. OAuth sign-up (ADR 0017)
    uses `oauth_signup`.
- `CONSENT_REQUIRED_AT_REGISTRATION=false` until milestone 5.11. 5.11 sets it to true (forced in
  strict environments) once A1 has shipped to staging. Old field-test APKs keep registering
  until then.

### 4. Withdrawal

- `health_data`, `terms`, `privacy`: `POST /v1/me/consents/withdraw` answers 409
  `withdraw_via_account_deletion`. Withdrawing consent to the processing the service is built
  on is an account deletion request (ADR 0010 §1): relatives, detection and push stop at the
  request, and data is erased within the grace period. The app opens the deletion dialog.
- `catalog_contribution` (milestone 5.2b; 501 until then):
  - **Ledger.** A full-access write that sets `gtin_link_shared=true` with version V inserts an
    active `catalog_contribution` / `medication_link` row in the same transaction, if none
    exists for V. It adds no journal entry. Editors never record a consent (ADR 0015 §4), and
    replaying a push is idempotent.
  - **Withdraw.** Runs under the user's journal lock: sets `withdrawn_at` and calls the
    journaled `reset_consent_in_profiles` for the profiles the user owns. Other devices see the
    reset links in their next pull. Response 200 `{reset_links: n}`; a replay returns n = 0.
    Re-ticking a link afterwards inserts a new record (ADR 0014 §2–§3 lower the count).
  - The strict-environment refusal of `CATALOG_CONTRIBUTIONS_ENABLED` stays after 5.2b, until
    the final legal texts exist (Q5); lifting it is a one-line PR.

### 5. Re-consent gate for existing accounts (Q3)

Accounts created before consents existed, or before a version bump, have a non-empty
`missing`. On its next launch the app shows a blocking consent screen until the kinds are
recorded through `POST /v1/me/consents`. Local reminders keep firing behind the gate, and the
server does not refuse sync or any other request for missing consent. Processing of
already-held data during the gate is a legal item (§9).

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
  The account's own `hidden` and `anonymous` medications are included. Every new table
  (`consents`, `entitlements`, `promo_redemptions`, `admin_audit`, `auth_identities`,
  `purchases`) gets a decision when it is created.
- **Snapshot isolation.** `collect_account_data` reads every table in one `REPEATABLE READ`,
  read-only transaction, so there are no orphan rows between tables. `build_archive` is pure
  and runs in `to_thread`.

### 8. Export transport (Q6)

Table `data_exports (id, user_id fk CASCADE, device_id, status, error_code, requested_at,
lease_until, ready_at, expires_at, size_bytes, archive bytea null)`:
- status CHECK IN (`queued`, `running`, `ready`, `downloaded`, `failed`, `expired`), and
  CHECK `archive IS NULL OR status = 'ready'`;
- classified `medical`, export `none`, erased with the account;
- a deletion request deletes the account's exports in the same transaction.

Flow, behind `FEATURE_DATA_EXPORT=false` (`FeaturesOut.data_export_enabled`):
- **Request.** `POST /v1/me/export` → 202 with the export id. Replaying while an export is
  active → 200 with the same export. A new request within `EXPORT_COOLDOWN_SECONDS=3600` →
  429 `export_rate_limited`. Flag off → 403.
- **Job.** ARQ cron `build_data_exports` runs every minute and takes no arguments:
  - claims `queued` or lease-expired rows with `FOR UPDATE SKIP LOCKED`, so a crashed worker's
    row is picked up again;
  - builds, checks `EXPORT_MAX_BYTES` (64 MiB; over the cap the export fails with
    `export_too_large`) and encrypts (§9);
  - skips accounts pending deletion;
  - in the same cron, nulls the archive and marks the row `expired` once past `expires_at`
    (`EXPORT_TTL_HOURS=24`), and deletes metadata rows after `EXPORT_RETENTION_DAYS=7`.
- **Status.** `GET /v1/me/export/{id}`; a foreign id is 404.
- **Download.** `POST /v1/me/export/{id}/download`:
  - requires the bearer of the same account **and** the `X-Device-ID` that made the request.
    A mismatch is 404, so the archive cannot reach another device of the same account;
  - 200 returns the zip with `Cache-Control: no-store`. In one committed transaction the row
    becomes `downloaded` and the archive is nulled: single download;
  - 409 `export_not_ready` / `export_failed`, 410 `export_gone` after download or expiry.
- POST, not GET, so the export id and the response never sit in URLs, proxy caches or
  history. The archive is never e-mailed and never pushed. A notification "export ready" is
  not in this slice.
- On the device (A1) the file goes to app-private storage excluded from backups, is offered
  to the share sheet, and is deleted after sharing.

### 9. Encryption at rest

- AES-256-GCM. Per export, the key is `HKDF-SHA256(ikm=DATA_ENCRYPTION_KEY,
  salt=export_id, info="pillpal-export/v1")`, the nonce is random, and the stored blob starts
  with a key-id prefix byte. The per-export key means a leaked blob plus another export's key
  decrypts nothing.
- `DATA_ENCRYPTION_KEY`: at least 32 characters, per region and environment. It must differ
  from `JWT_SECRET` and `PROMO_CODE_HMAC_KEY` (startup refuses otherwise), and strict
  environments refuse the flag without it. The same root key with a different `info` is used
  for Apple refresh tokens (ADR 0017); the `info` strings keep the derived keys separate.
- The key lives in the regional environment only. Archives never leave the region except as
  the user's own download.
- Key rotation (the use of the key-id byte) and whether the export id is also bound as AAD are
  decided in milestone 5.5.

### 10. Needs legal confirmation

1. Consent texts and versions (placeholders now). Whether one combined `terms`/`privacy`
   screen with a separate health-data checkbox satisfies "отдельным документом" (TZ §5).
2. Withdrawal of health-data consent implemented as a deletion request with up to 30 days of
   blocked storage (ADR 0010 §4).
3. Erasing consent records with the account, with no retained proof (Q4).
4. Continued processing for existing accounts while the re-consent gate is open (Q3).
5. The export exclusions and the D1 heir rule of `docs/spec/export.md`.
6. A 1-hour cooldown and a 24-hour single download as adequate access for GDPR art. 15/20 and
   152-FZ art. 14. Export import for a region change (TZ §1) is a later follow-up (Q6).

## Consequences

Positive:
- Consent is provable per kind and version, and both the registration path and the in-app
  path write the same ledger.
- Contribution withdrawal reuses the journaled reset, so it converges on every device without
  a sync-protocol change.
- An export is consistent, deterministic, encrypted in its region, readable once by one device,
  and gone within 24 hours.

Negative:
- `bytea` archives live in PostgreSQL, up to 64 MiB each, for at most 24 hours. Backups taken
  in that window contain encrypted exports, so backup retention must follow ADR 0010 §4.
- The 409 on health-data withdrawal is a deliberate dead end in the API; the app must route
  users to deletion.
- Until 5.11, accounts can still be created without consent records. The gate (Q3) catches
  them at the next launch.

Follow-ups:
- 5.2a, 5.2b, 5.5, A1, 5.11.
- Decide whether a deletion request also stamps `withdrawn_at` on active consents (5.2a).
- Key rotation and AAD (5.5).
- Export import for a region change.
- Align `docs/phase5-plan.md` 5.1 with the spec, which exports `refresh_tokens` without
  `token_hash`.

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
