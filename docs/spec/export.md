# Account data export: archive format v1

Status: milestone 5.1 (policy and builder) and 5.5 (delivery, below). Code: `backend/app/services/export_archive.py`; policy: `TABLE_CLASSIFICATION` in
`backend/app/services/personal_data.py`.

## What is exported

The data subject's own rows, found through `owner_ref` (user, profile, medication):

- profiles the account **owns**, including a managed profile inherited through the D1 transfer
  (ADR 0005 section 5, ADR 0010); profiles it only co-guards or views are not exported;
- everything under those profiles: medications (all fields, whatever their privacy level,
  including the Phase 4 catalog and GTIN link fields), schedules, dose events;
- the account row, its devices and its push tokens (provider and timestamps only);
- the account's sessions (`refresh_tokens`: devices and times, no token hash);
- `entitlements` of the account (kind, source, validity, revocation; ADR 0018 section 1);
- `promo_redemptions` of the account (which code id it redeemed, when, and the entitlement it got; never
  the code, ADR 0018 section 3);
- `purchases` of the account (store, product, the store's purchase identifier, environment, dates; never the
  signed transaction or token, which is not stored; ADR 0018 section 6);
- `auth_identities` of the account (provider, the account's own subject at that provider, the address it asserted
  when linked, times; never the encrypted provider token; ADR 0017 section 2);
- `admin_audit` rows about the account (what an operator did to it: action, kind, time, entitlement id). The
  operator columns `actor`, `os_user` and `host` are the operator's data and are not exported;
- relations: grants the account holds, grants on profiles it owns, invites it created, invites it
  consumed and invites on profiles it owns. The other party appears only as an opaque user id: no e-mail.

The account row includes `deletion_requested_at` and `erase_after`. Soft-deleted rows
(`deleted_at` set, content already erased by the tombstone rule) and archived profiles are
included as they are.

Other accounts' content never enters the archive. Row order inside a table follows the primary
key.

## Not exported (decision per table in `personal_data.py`)

| Table or column | Why |
|---|---|
| `users.password_hash`, `password_changed_at`, `tokens_not_before` | credentials and their bookkeeping |
| `invites.token_hash`, `push_tokens.token`, `refresh_tokens.token_hash` | credentials |
| `profile_grants.granted_seq` | internal sync cursor |
| `admin_audit.actor`, `os_user`, `host` | the operator's own data, not the subject's |
| `auth_identities.provider_refresh_token_enc` | a credential |
| `email_codes` | one-time credentials, short lived |
| `sync_changes` | derived journal; the exported rows carry the same facts |
| `push_outbox`, `missed_dose_alerts` | transient (days) |
| `promo_codes` | system table: campaign labels and keyed digests, shared by all accounts |
| `alembic_version`, `detector_state` | system tables |

A test fails if a table has no decision or an exported column looks like a secret
(`password*`, `*_hash`, `*token*`, `*_enc`, `*digest*`).

## Format

A zip file (deflate). Member order is fixed: `manifest.json`, then `tables/<table>.json` in
alphabetical table order. Member timestamps and permissions are fixed (Unix, `0600`), so the
same build (same code, same data, same `generated_at`) gives the same bytes; a different zlib
build may compress differently, so compare decompressed members across builds.

`manifest.json`:

```json
{
  "format_version": 1,
  "region": "ru",
  "generated_at": "2026-11-10T12:00:00+00:00",
  "tables": {"dose_events": 3, "medications": 2, "users": 1}
}
```

`tables` has one entry per exported table with its row count (0 included); every entry has a
file. `tables/<table>.json` is a JSON array of objects, one per row, keyed by column name,
UTF-8 (non-ASCII text is kept as is). Datetimes are UTC ISO 8601 strings, UUIDs and decimals
are strings, `jsonb` columns are nested JSON, nulls stay `null`.

A new format version is required for any removed or renamed column; adding a column or a table
does not change `format_version`.

## Consistency

`collect_account_data` runs in one `REPEATABLE READ`, read-only transaction (set before the first
query), so every table is read at the same moment: no medication without its profile, no dose
event without its medication. The builder refuses data that does not hold exactly the exported
tables (`ValueError`), so a table cannot silently go missing.

## Delivery (milestone 5.5, ADR 0016 sections 8 and 9)

Behind `FEATURE_DATA_EXPORT` (off by default; needs the `DATA_ENCRYPTION_KEYS` keyring). Code:
`backend/app/api/me_export.py`, `services/exports.py`, `jobs/data_exports.py`,
`services/data_encryption.py`.

- `POST /v1/me/export` `{password}` (step-up; 401 `reauth_required` / `invalid_password`): 202 with the
  export, 200 for a replay by the same session, 429 `export_rate_limited` within
  `EXPORT_COOLDOWN_SECONDS` of an export that was not downloaded (also for another session of the
  account), 403 `feature_disabled`. A new request mails a notice with no data and no link.
- `GET /v1/me/export/{id}`: status. `POST /v1/me/export/{id}/download`: the zip, once, only for the
  session (`sid` = refresh family) that asked and only while that session is signed in; 404 for
  any other, 409 `export_not_ready` / `export_failed`, 410 `export_gone`.
- The claim is one statement that returns the *old* archive while nulling it (a bare
  `UPDATE ... SET archive = NULL RETURNING archive` would return `NULL`): `UPDATE ... FROM (SELECT ...
  FOR UPDATE) RETURNING old.archive`. It commits before the bytes are sent.
- The worker (`build_data_exports`, every minute) claims with `FOR UPDATE SKIP LOCKED`, builds,
  refuses more than `EXPORT_MAX_BYTES`, encrypts (AES-256-GCM, HKDF per export id) and stores the
  blob; ready archives are nulled after `EXPORT_TTL_HOURS`, metadata is deleted after
  `EXPORT_RETENTION_DAYS`, a deletion request deletes the account's exports.

## Needs legal confirmation

- Not exporting `sync_changes`, `push_outbox`, `missed_dose_alerts` and `email_codes`
  (derived, transient or credential data).
- The heir of a managed profile (D1) receives its history from before the transfer, including
  dose events written by the former owner.

## Privacy

The archive is medical data: it is built in memory for the caller only, never logged, never put
into a URL, an e-mail subject or a push payload. It is region-local like all other data.
