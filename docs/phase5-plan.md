# Phase 5 — functional slice (code-only) — delivery plan

Scope source: `docs/phase4-plan.md` → "Appendix — Phase 5 functional slice" (owner decisions on promo codes and
`ads_removed`, 2026-10-22) and "Review log (2026-11-09)". Owner priority (2026-11-10): client-server functionality
first, backend-first, everything buildable without external accounts. Deployment, store accounts and legal work stay
out of scope (appendix "Needs the owner").

## Owner decisions (2026-11-10)
- **Q1 OAuth matrix follows TZ §1.** RU: VK ID and Yandex ID on Android only (RU-iOS is e-mail only); EU: Apple on
  iOS, Google on Android and iOS. The Phase 4 appendix line about Apple in RU is superseded.
- **Q2** The one-time purchase grants `ads_removed` and `limits_lifted`; each promo code grants the kind set at
  creation.
- **Q3** Existing accounts without consent records get a blocking consent screen in the app at next launch; local
  reminders keep firing; the server does not refuse sync.
- **Q4** Consent records are erased with the account until legal review asks to keep a proof.
- **Q5** The strict-environment refusal of `CATALOG_CONTRIBUTIONS_ENABLED` stays after 5.2b, until the final legal
  texts (then a one-line PR).
- **Q6** Export: one request per hour, 64 MiB cap, 24 h TTL, single download; export import for a region change is a
  later follow-up.
- **Q7** Providers without a verified e-mail (VK ID): e-mail entry with a mailed code at sign-up; no account is
  created without a verified e-mail.

## Requirements
- **Consent records**: health data, terms, privacy, catalog contribution; version, timestamp, withdrawal.
  Registration records the current health-data version; withdrawing health data goes through account deletion
  (ADR 0010); withdrawing catalog contribution resets the per-medication links (ADR 0015 §4).
- **Data export**: `POST /v1/me/export` → ARQ job → JSON archive built from the `TABLE_CLASSIFICATION` inventory,
  encrypted in-region, single-use short-TTL download bound to the session and never in a URL, purged at 24 h, never
  e-mailed, rate-limited.
- **OAuth framework behind flags**: `auth_identities`, an `IdentityProvider` protocol, the provider × region ×
  platform matrix (Q1), Apple/Google ID-token verification (JWKS, `iss`/`aud`/`nonce`), VK ID/Yandex ID code
  exchange, no auto-merge of accounts, every provider off without its client id.
- **Payments backend** behind `FEATURE_PAYMENTS=false`: `purchases`, a verifier protocol, StoreKit 2 JWS
  verification against a test chain, RuStore Pay and Play stubs, soft limits wired to entitlements.
- **`ads_removed` entitlement per account** from purchase, promo or admin grant; promo codes from an admin CLI,
  stored as an HMAC digest; redeem rate-limited with a lockout and a breaker; direct grant by e-mail through the CLI,
  audited.
- Lower priority, last and optional: remote config, backend Sentry wiring, analytics allowlist, client region
  selection.

## Assumptions
- Every new flag defaults to off. Strict environments (`staging`, `prod`; `STRICT_ENVIRONMENTS`) refuse unsafe
  combinations at startup.
- New tables use server-generated ids; they are not sync entities and never appear in `/v1/sync/*`.
- External providers are faked: JWKS and provider endpoints through `httpx.MockTransport` with keys generated in the
  test; StoreKit 2 with a generated root/intermediate/leaf chain with the Apple marker OIDs (the pinned Apple Root CA
  G3 is the default; a root override only outside strict environments).
- `app/config.py` is over the 400-line limit: new settings go into mixins (`app/settings_consent.py`,
  `settings_entitlements.py`, `settings_export.py`, `settings_oauth.py`, `settings_payments.py`), each with its own
  strict validators.
- App work starts after the UI consistency pass. Backend milestones do not touch `app/lib/**`.
- Consent and promo texts are versioned placeholders until legal review.

## Impact
- `backend/`: migrations 0017–0023; new `app/admin/`, `app/oauth/`, `app/payments/`, services
  `consents, consent_ledger, entitlements, promo, data_export, export_archive, identities, oauth_sign_in, purchases`;
  routers `me_privacy, me_entitlements, oauth, purchases`; changes in `personal_data.py`, `erasure.py`,
  `account_deletion.py`, `auth.py`, `observability.py` (`SENSITIVE_KEYS`, `SENTRY_SECRET_KEYS`), `worker.py`,
  `api/auth.py` (`FeaturesOut`, `UserOut.has_password`), `invites.py` (soft limits); `spec/openapi.json` refreshed on
  every route change.
- `docs/`: ADRs 0016–0018, `docs/spec/export.md`, this plan; README, staging and CLAUDE.md in 5.13 or a doc PR.
- `infra/.env.example`: new variables, flags off.
- `app/`: only A1–A4. `packages/pillpal_core`, `spec/*-vectors` and `catalog/` do not change.
- **No schedule, dose-state or GTIN semantics change. No sync protocol change.**

## Milestones

| # | Milestone | Migration | Depends on | Parallel with |
|---|---|---|---|---|
| 5.0 | Docs: ADRs 0016–0018, this plan | — | — | 5.1 |
| 5.1 | Export policy in the inventory + archive builder; single-head test | — | — | 5.0 |
| 5.2a | Consent records: table, API, registration (optional field) | `0017_consents` | 5.1 | 5.3 |
| 5.2b | Catalog-contribution consent ledger + withdraw | — | 5.2a | 5.4, 5.5 |
| 5.3 | Entitlements + admin audit + `python -m app.admin entitlement` | `0018_entitlements`, `0019_admin_audit` | 5.1 | 5.2a |
| 5.4 | Promo codes: CLI, redeem, lockout, breaker | `0020_promo_codes` | 5.3 | 5.2b, 5.5 |
| 5.5 | Export delivery: request, job, encryption, download, purge | `0021_data_exports` | 5.1 | 5.2b, 5.4 |
| 5.6 | OAuth core: identities, protocol, matrix, sign-in/sign-up with a fake provider | `0022_auth_identities` | 5.2a | 5.4, 5.5 |
| 5.7 | OAuth account management: link, unlink, deletion re-auth, restore | — | 5.6 | 5.8–5.10 |
| 5.8 | Apple + Google verifiers; Apple code exchange and revoke | — | 5.6 | 5.7, 5.9, 5.10 |
| 5.9 | VK ID + Yandex ID code exchange | — | 5.6 | 5.7, 5.8, 5.10 |
| 5.10 | Payments backend: verifier protocol, StoreKit 2, stubs, soft limits | `0023_purchases` | 5.3 | 5.7–5.9 |
| R10 | Names and relatives (owner redesign): PR1 name required at sign-up, rename yourself in Settings | — | — | — |
| A1 | App: consent at registration, re-consent gate, privacy settings, export | — | UI pass, 5.2b, 5.5, R10 | — |
| 5.11 | Backend: consents required at registration | — | A1 | A2 |
| A2 | App: entitlement cache, promo redeem, ads gate | — | UI pass, 5.4, A1 | 5.11 |
| 5.12 | *(optional)* Remote config `GET /v1/config` | — | 5.3 | 5.13 |
| 5.13 | *(optional)* Backend Sentry wiring + docs sync | — | — | 5.12 |
| A3 | *(optional)* App: analytics event allowlist, no-op sink | — | A2 | — |
| A4 | *(optional)* App: region selection + remote config read | — | A3, 5.12 | — |

Not in this slice: app OAuth buttons and SDKs (need client ids), store purchase SDKs, App Store Server
Notifications, export import for a region change, IP geolocation.

### Migration ordering (no second head on `main`)
- Reserved chain: `0016_med_catalog_ref_index` → `0017_consents` → `0018_entitlements` → `0019_admin_audit` →
  `0020_promo_codes` → `0021_data_exports` → `0022_auth_identities` → `0023_purchases`; 0024 spare.
- A branch develops on the current head of `main`; before merge it rebases and points `down_revision` at its
  reserved predecessor, which must already be merged. Merge order follows the revision number.
- `tests/test_migrations.py::test_single_head` (5.1) pins the expected head; every migration milestone updates it.
- Parallel branches collide textually in `personal_data.py`, `erasure.py`, `observability.py`, `config.py` and
  `main.py`; the second PR rebases.

---

### 5.0 Docs and contracts
- `docs/adr/0016-consent-records-and-data-export.md` (kinds, versions, withdrawal, export format and transport,
  encryption key derivation); `docs/adr/0017-oauth-identities-and-account-linking.md` (matrix, no auto-merge, signup
  ticket, e-mail fallback, re-auth for deletion, Apple token revocation);
  `docs/adr/0018-entitlements-promo-codes-and-payments.md` (kinds, sources, effective state, promo hashing, lockout
  and breaker, admin audit, StoreKit chain).
- `architect` authors; one pass by `privacy-compliance-reviewer` and `security-reviewer`; findings go to a
  "Review log" section here.

### 5.1 Export policy and archive builder (no migration, no endpoint)
- `personal_data.py`: `TableInfo` gains `export: Literal["rows", "none"]`, `export_exclude`, `export_reason`.
- `services/export_archive.py`: `collect_account_data(session, user_id)` resolves rows through `owner_ref`, streamed
  with `yield_per`; `build_archive(data, *, region, now) -> bytes` is pure (zip with `manifest.json` and
  `tables/<table>.json`), run in `to_thread`.
- Rows: `users` (no `password_hash`), `profiles`, `medications` (all Phase 4 fields), `schedules`, `dose_events`,
  `devices`, `profile_grants` and `invites` (both directions, no `token_hash`), `push_tokens` (provider and timestamps
  only), `refresh_tokens` (session history, no `token_hash`; changed after the 5.1 privacy review, see
  `docs/spec/export.md`). None, with a reason: `email_codes`, `sync_changes`, `push_outbox`, `missed_dose_alerts`,
  system tables.
- Tests: every non-system table has a decision; no exported column matches `password*|*_hash|*token*|*_enc|*digest*`;
  needle test over every exportable table; another account's needles never appear (including co-guarded profiles);
  own `hidden` and `anonymous` medications included; D1 heir included; manifest counts; deterministic output.
- Reviewers: `privacy-compliance-reviewer`, `code-reviewer`.

### 5.2a Consent records (`0017_consents`)
- `consents (id, user_id fk CASCADE, kind CHECK IN ('health_data','terms','privacy','catalog_contribution'),
  version int CHECK 1..MAX, source CHECK IN ('registration','in_app','oauth_signup','medication_link'), accepted_at,
  withdrawn_at null, CHECK withdrawn_at >= accepted_at)`; partial UNIQUE `(user_id, kind, version) WHERE withdrawn_at
  IS NULL`; index `(user_id, kind)`; personal, export rows, erased.
- Settings: `CONSENT_VERSIONS_{HEALTH_DATA,TERMS,PRIVACY}=[1]` per region; `catalog_contribution` reuses
  `GTIN_LINK_CONSENT_VERSIONS`; `CONSENT_REQUIRED_AT_REGISTRATION`: a validator refuses `false` when
  `ENVIRONMENT=prod` (forced true from the first prod deployment); dev and staging default `false` until 5.11.
- Deletion stamps withdrawal (ADR 0016 §4): the deletion request sets `withdrawn_at = now` on every active
  `health_data`, `terms` and `privacy` record in the same transaction; a restored account has a non-empty `missing`.
- `POST /v1/auth/register`: optional `consents: [{kind, version}]` (max 3, unique kinds, baseline kinds only: `catalog_contribution` → 422 `unsupported_consent_kind`; the 5.6 `oauth_signup` path reuses the same validator); when present or required it
  must contain the current health_data, terms and privacy versions (422 `consent_required`; unknown version 422
  `unsupported_consent_version`); validation does not depend on whether the e-mail exists; a known address records
  nothing and answers the same 202.
- `GET /v1/me/consents` → `{current, records, missing}`; `POST /v1/me/consents {kind, version}` → 201, active replay
  200, non-current 422, `catalog_contribution` 422, rate-limited; `POST /v1/me/consents/withdraw {kind}`: health_data,
  terms, privacy → 409 `withdraw_via_account_deletion`; catalog_contribution → 501 until 5.2b.
  `FeaturesOut.consent_required_kinds`.
- Tests: register with/without consents (flag off and on), known e-mail, wrong version, extra field, 401, replay,
  withdraw 409, deletion stamps `withdrawn_at` and restore leaves `missing` non-empty, prod refuses
  `CONSENT_REQUIRED_AT_REGISTRATION=false`, erasure and export, migration round-trip.
- Reviewers: `privacy-compliance-reviewer`, `security-reviewer`, `code-reviewer`.

### 5.2b Catalog-contribution consent ledger and withdrawal
- A full-access write that sets `gtin_link_shared=true` with version V (through `with_consent`) inserts an active
  `consents` row (`catalog_contribution`, `medication_link`) if none exists for V, in the same transaction, without a
  new journal entry.
- `POST /v1/me/consents/withdraw {kind: "catalog_contribution"}` under the user's journal lock sets `withdrawn_at` and
  calls the journaled `reset_consent_in_profiles` for profiles the user owns; 200 `{reset_links: n}`; replay n=0.
- Only the profile owner can grant (owner decision 2026-11-10): a co-guardian's grant is refused with
  `forbidden_field` (403 on REST); clearing and echoes stay allowed. A grant older than the user's latest withdrawal is
  not a grant. Published consensus links stay in the catalog (ADR 0014 §4); withdrawal only removes the person from
  future snapshots.
- Tests: one row per V; push replay idempotent; editors never record; withdraw resets links seen by another device's
  pull; double withdraw safe; the strict refusal of `CATALOG_CONTRIBUTIONS_ENABLED` stays (Q5).
- Reviewers: `offline-sync-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`.

### 5.3 Entitlements, admin audit, admin CLI (`0018_entitlements`, `0019_admin_audit`)
- `entitlements (id, user_id fk CASCADE, kind CHECK IN ('ads_removed','limits_lifted'), source CHECK IN
  ('purchase','promo','admin_grant'), source_ref uuid null, granted_at, expires_at null, revoked_at null, CHECK
  expires_at > granted_at)`; personal, export rows, erased.
- `admin_audit (id, at, actor text 1..64 without '@', action CHECK IN (...), target_user_id null fk ON DELETE SET
  NULL, object_id null, kind null)`; export rows about the user; on erasure the row stays without the person.
- Pure `domain/entitlements.py::effective(rows, now)`.
- `GET /v1/me/entitlements` → `{ads_removed, limits_lifted, items, server_time}`, `Cache-Control: private,
  no-store`; works with `FEATURE_PAYMENTS=false`.
- CLI `python -m app.admin entitlement grant --kind ads_removed [--expires] --actor` (e-mail from stdin), `revoke
  --account-id --kind --actor`; unknown or pending-deletion account → exit 2; replay no-op; audit with account id only.
- Audit (ADR 0018 §5): `admin_audit` also has `os_user` and `host` (operator data, excluded from export);
  `object_id` is a promo, entitlement or purchase id, never a user id; erasure nulls `object_id` where
  `target_user_id` was the erased user; `ADMIN_AUDIT_RETENTION_DAYS=365` purged by the daily job; `actor` is
  self-declared, so the CLI records OS user and host; run only through `docker compose exec` / `run --rm`, never
  from CI; `promo create --count` capped at 100.
- Tests: effective-state table; 401; co-guardians and relatives do not inherit; CLI on real PostgreSQL; audit without
  e-mail; erasure and export; migration round-trips.
- Reviewers: `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`.

### 5.4 Promo codes (`0020_promo_codes`)
- `promo_codes (id, code_digest UNIQUE, label 1..64, kind, grant_days null, max_activations >= 1, activations 0..max,
  expires_at null, disabled_at null, created_at)`, classification `system`; `promo_redemptions (code_id, user_id fk
  CASCADE, redeemed_at, entitlement_id, PK (code_id, user_id))`, personal, export rows, erased.
- Settings: `FEATURE_PROMO_CODES=false`; `PROMO_CODE_HMAC_KEY` (32 random bytes, base64, decoded and length-checked at
  startup; per region; ≠ `JWT_SECRET` and every `DATA_ENCRYPTION_KEYS` key; required in strict when on);
  `PROMO_CODE_LENGTH=20` (min 16); `PROMO_MAX_FAILED_PER_DAY=5`; breaker: > 200 failures per 3600 s is alert-only
  (metric and log code `promo_breaker_tripped`); for 900 s it blocks only callers with ≥ 1 failure today.
- Code: alphabet `23456789ABCDEFGHJKMNPQRSTUVWXYZ` from `secrets`, shown grouped. Normalized: spaces and hyphens
  removed; every other character must be ASCII and in the alphabet (or its ASCII lowercase) **before** uppercasing;
  otherwise invalid. Stored as `HMAC-SHA256(key, normalized)`; lookup by the UNIQUE `code_digest` (no
  `compare_digest` claim).
- CLI: `promo create --label --kind --max-activations [--expires] [--grant-days] [--count ≤ 100] --actor` prints
  codes once; `promo list` (never digests); `promo disable <id>`.
- `POST /v1/me/promo/redeem {code ≤ 64}` → 200 entitlements. Order: per-user limit, per-IP bucket, daily lockout,
  breaker, lookup. One transaction, explicit outcomes: (1) insert redemption ON CONFLICT DO NOTHING; on conflict
  → replay, return the existing entitlements with 200, never re-grant a revoked one, counter untouched; (2) guarded
  `UPDATE … activations + 1 … RETURNING` with no row → roll back, 400, one failure; (3) insert the entitlement.
  Each failure runs `INCR` then `EXPIRE` before the response. Errors: 422 `validation_error`; 400
  `invalid_promo_code` (unknown, expired, exhausted, disabled, bad alphabet — identical, counted as failures); 429
  `promo_locked` with `Retry-After`; 429 `rate_limited`; 503 `promo_unavailable` (Redis down, fail closed, or the
  breaker for a caller with ≥ 1 failure today); 403 `feature_disabled`. `promo_code` added to `SENSITIVE_KEYS` and
  `SENTRY_SECRET_KEYS`.
- Tests: happy, 401, 422, identical errors, replay (no re-grant of a revoked entitlement), concurrency on the last
  activation, rollback on the guarded update, lockout, breaker alert-only and per-caller block, `INCR`/`EXPIRE` before
  response, ASCII check before uppercasing, rate limits, code never in logs or Sentry, key ≠ `JWT_SECRET`, strict
  without key refuses, CLI, migration round-trip.
- Reviewers: `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`.
- **Implementation notes (5.4):** `entitlements.source_ref` of a promo grant is the `promo_codes.id` (no foreign key); the
  redemption's `entitlement_id` is a deferred foreign key, because the redemption row is inserted before the entitlement.
  Settings beyond the list above: `PROMO_LOCKOUT_WINDOW_SECONDS=86400`, `PROMO_BREAKER_WINDOW_SECONDS`,
  `PROMO_BREAKER_BLOCK_SECONDS`, `PROMO_RATE_LIMIT_PER_USER=10`, `PROMO_RATE_LIMIT_PER_IP=30`,
  `PROMO_RATE_LIMIT_WINDOW_SECONDS=900`. There is no metrics backend yet: the breaker "metric" is the log code
  `promo_breaker_tripped` (once per block period). The separation of `PROMO_CODE_HMAC_KEY` from every `DATA_ENCRYPTION_KEYS` key lands with 5.5,
  together with the keyring (until then only `JWT_SECRET` is compared). The lockout slot is reserved in `check` and released
  on every outcome but a rejection (review fix). `Settings` now sets `hide_input_in_errors`, so a startup validation error never echoes secrets.
  `admin_audit.action` gains `promo_create` and `promo_disable` (`ck_admin_audit_action` is replaced in 0020; the downgrade
  deletes those rows first).

### 5.5 Export delivery (`0021_data_exports`)
- `data_exports (id, user_id fk CASCADE, family_id uuid, status CHECK IN
  ('queued','running','ready','downloaded','failed','expired'), error_code CHECK IS NULL OR IN
  ('export_too_large','export_build_failed'), requested_at, lease_until, ready_at, expires_at, size_bytes,
  archive bytea null, CHECK archive IS NULL OR status='ready')`; medical, export none, erased; a deletion request
  deletes the account's exports in the same transaction.
- **Session binding:** the access JWT gains `sid` = refresh-token `family_id` (ADR 0016 §8); tokens without `sid`
  cannot download (the app signs in again).
- Settings: `FEATURE_DATA_EXPORT=false`; `DATA_ENCRYPTION_KEYS={id: base64}` (32 random bytes per key, decoded and
  length-checked at startup, none equal to `JWT_SECRET` or `PROMO_CODE_HMAC_KEY`) and `DATA_ENCRYPTION_KEY_ID`
  (ADR 0016 §9); `EXPORT_TTL_HOURS=24`; `EXPORT_COOLDOWN_SECONDS=3600`; `EXPORT_MAX_BYTES=64 MiB`;
  `EXPORT_RETENTION_DAYS=7`; per-user rate limits for status and download in `settings_export.py`.
- Encryption (ADR 0016 §9): AES-256-GCM; blob `key_id(1) || nonce(12) || ciphertext||tag`; per-row key
  `HKDF-SHA256(keyring key, salt=export id, info="pillpal-export/v1")`; AAD `key_id || purpose || row_id`; rotation
  by re-encrypting with the current key, key removed only when no row references it.
- ARQ cron `build_data_exports` (every minute, no arguments): claims queued or lease-expired rows with `FOR UPDATE
  SKIP LOCKED`, builds and encrypts; nulls archives and expires rows past `expires_at`; deletes metadata past
  retention; skips pending-deletion accounts.
- `POST /v1/me/export`: step-up re-auth (`{password}` or `{reauth: {provider, platform, assertion}}`, the rules of
  `DELETE /v1/me`; failed re-auth returns the same errors); → 202 with the export id; active export replay → 200 (no
  notice); a new request mails a notice "an export was requested" with no data and no link; cooldown: a new request
  within 3600 s of an export not in `downloaded` → 429 `export_rate_limited` (downloaded rows do not count); flag
  off → 403.
- `GET /v1/me/export/{id}` (foreign → 404; per-user rate limit).
- `POST /v1/me/export/{id}/download`: the bearer's account and `sid` must match `user_id` and `family_id`, mismatch →
  404. One atomic statement: `UPDATE data_exports d SET status='downloaded', archive=NULL FROM (SELECT id, archive
  FROM data_exports WHERE id AND user_id AND family_id = :sid AND status='ready' AND expires_at > :now AND the
  session's refresh family is not revoked FOR UPDATE) old WHERE d.id = old.id RETURNING old.archive` (the old value:
  a bare `RETURNING archive` would be NULL); concurrent downloads cannot both
  win. 200 zip with `Cache-Control: no-store` and `Content-Disposition: attachment;
  filename="pillpal-export-<region>-<YYYYMMDD>.zip"` (UTC date of `ready_at`). The claim commits before the bytes are
  sent; a transfer failure after the commit loses the export (user requests again). 409 `export_not_ready` /
  `export_failed`, 410 `export_gone`. `FeaturesOut.data_export_enabled`.
- **Step-up** is the password in a required body field, so a missing proof is 422 like `DELETE /v1/me`; the
  OAuth form joined it in 5.7 (done: `{reauth: {...}}`, ADR 0017 §8), so `FEATURE_DATA_EXPORT` may be enabled
  together with OAuth sign-up.
- POST, not GET: the response is never cached or replayed from history; the path id is an opaque UUID that grants
  nothing without the bearer token and the matching `sid`.
- Tests: full path on a fake clock; step-up required (401 on a missing or failed re-auth); notice sent once per new
  request and no data in it; second download 410; concurrent download race (one winner); expiry; other session 404;
  no `X-Device-ID` dependency; foreign 404; 401; replay; cooldown with `downloaded` excluded; deletion purges; size
  limit `export_too_large`; lease re-claim; ciphertext without needles; AAD binding (a blob moved to another row
  fails); keyring key rotation; strict key refusals; migration round-trip.
- Reviewers: `privacy-compliance-reviewer`, `security-reviewer`, `code-reviewer`.

### 5.6 OAuth core (`0022_auth_identities`)
- `auth_identities (id, user_id fk CASCADE, provider CHECK IN ('apple','google','vk_id','yandex_id'), subject
  1..255, email_at_link null, created_at, last_used_at, provider_refresh_token_enc bytea null, UNIQUE (provider,
  subject))`; personal, export rows without `*_enc` **with `subject`** (own id, ADR 0016 §7; the API never returns
  it), erased.
- Passwordless accounts: an unusable sentinel in `users.password_hash`; `PasswordHasher.verify` treats it like an
  unknown user (dummy hash, constant time); `UserOut.has_password`; password reset sets a real password.
- `domain/auth_providers.py` matrix (Q1): `ru`: `vk_id` {android}, `yandex_id` {android}; `eu`: `apple` {ios},
  `google` {android, ios}. `oauth/base.py` `IdentityProvider` protocol; `oauth/fake.py` test-only (refused outside
  dev/test).
- Settings: `FEATURE_OAUTH=false`, `OAUTH_NONCE_TTL_SECONDS=300`, `OAUTH_SIGNUP_TICKET_TTL_SECONDS=600`,
  `OAUTH_REAUTH_MAX_AGE_SECONDS=300`, `OAUTH_HTTP_TIMEOUT_SECONDS=10`; every environment refuses Apple/Google settings
  in RU and VK/Yandex in EU; strict refuses partial provider configuration.
- `POST /v1/auth/oauth/nonce {purpose: sign_in|link|reauth}`: server nonce, ≥ 128 bits, Redis TTL 300 s, `GETDEL` on
  use, purpose-bound; the client never chooses the nonce. Rate limited per IP and per user.
- `GET /v1/auth/providers?platform=`; `POST /v1/auth/oauth/{provider}/sign-in`: known identity → 200 tokens (pending
  deletion → 403 with restore); verified e-mail of an existing **verified** account (`email_verified_at` set) → 409
  `oauth_account_exists` (no merge); otherwise 409 `oauth_signup_required` with a single-use `signup_ticket` (Redis
  `ot:`, sha256 key, 600 s, bound to region and platform). Not configured or not allowed by the matrix → 404; provider
  timeout or Redis down → 503 `provider_unreachable`; bad, replayed or wrong-nonce assertion → 401
  `invalid_provider_token`.
- `POST /v1/auth/oauth/sign-up {signup_ticket, region, locale, timezone, display_name?, consents, email?}`: order:
  validate the body (consents as ADR 0016 §3; body `region` must equal `REGION`, else 422 `validation_error`), then
  `GETDEL` the ticket (unknown, used, expired, other region or platform → 401 `invalid_provider_token`). Verified
  e-mail → 201; a verified sign-up over **any unverified row** (a password nobody confirmed, or the passwordless row of an
  unfinished fallback, whose pending entry goes too) with the same e-mail deletes that row in the same transaction
  and creates the account. Unverified (Q7) → e-mail required, 202 `VerificationSent`; the pending
  identity is held in Redis `ot:` with the code TTL (no table, so no erasure or export entry), bound to
  `(email, provider, subject)` and to a random `pending_token` returned by the 202 (only its hash is stored): the
  identity is attached only when `verify-email` carries the token with the code, otherwise the address is verified,
  the entry dropped and a "not linked" mail sent (a resend carries it too); the 202 path shares the `register`
  per-address budget; at verify time an e-mail that now belongs to a verified
  account runs the notice path and attaches nothing. Existing verified e-mail → same 202 and notice (no enumeration).
  Tickets, id tokens, codes, verifiers and nonces go to `SENSITIVE_KEYS` and `SENTRY_SECRET_KEYS`.
- Rate limits on sign-in, sign-up, nonce, link and re-auth, per IP and per ticket or user.
- Gate: `FEATURE_OAUTH=true` was refused in staging and prod until 5.7 (passwordless accounts need the OAuth re-auth
  form to delete or export); 5.7 removed it (done). The replay marker TTL is `min(exp - now, nonce TTL + 60 s)`.
- Sentinel (ADR 0017 §7): recognised before the Argon2 parser and `needs_rehash`, then dummy verify.
- Tests with the fake provider: sign-in, both sign-up paths, unverified-row replacement, collision, ticket single use
  (incl. body-invalid request does not burn it) and expiry, ticket for another region or platform, nonce single use
  and purpose, nonce replay, platform and region 404, flag off, 422, rate limit, Redis down → 503, sentinel password
  timing next to the unknown-user test, matrix misconfiguration, erasure and export (`subject` exported), migration
  round-trip.
- Reviewers: `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`.

### 5.7 OAuth account management
- `GET /v1/me/identities` (no subject); `POST /v1/me/identities` (201; replay 200; in use 409 `identity_in_use`);
  `DELETE /v1/me/identities/{id}` (204; foreign 404; last method 409 `last_sign_in_method`).
- **Link and unlink require the re-auth of `DELETE /v1/me`** (`{password}` or `{reauth: {provider, platform,
  assertion}}`, fresh `iat`, nonce purpose `reauth`, linked identity). A successful link or unlink mails a notice to
  the account address naming the provider only. Unlinking Apple revokes and clears `provider_refresh_token_enc`
  (best effort, as 5.8).
- `DELETE /v1/me` accepts `{password}` or `{reauth: {provider, platform, assertion}}` (fresh `iat`, linked identity);
  the password form is unchanged.
- OAuth sign-in while pending reuses `_offer_restore`.
- **Done in 5.7 (no migration).** `POST /v1/me/identities` carries the proof next to the new assertion; one shared
  `ReauthProof` schema (`schemas/reauth.py`, exactly one of `password` / `reauth`, `reauth` also carries `nonce` and
  `code_verifier`) serves `DELETE /v1/me`, `POST /v1/me/export`, link and unlink through `services/reauth.py`
  (`Reauthenticator`); assertion verification is shared in `services/oauth_verify.py`. `VerifiedIdentity.issued_at`
  (`iat`) drives freshness. Notices `identity_linked` / `identity_unlinked` (provider name only,
  `send_notice(provider=...)`). Unlink calls the hook `IdentityService._revoke_provider_token` (no-op until 5.8). The
  5.6 staging/prod gate on `FEATURE_OAUTH` is removed. Privacy LOW of 5.6 closed: a passwordless fallback row verified
  without the pending token has its baseline consents stamped withdrawn (re-consent gate runs; name, locale and time
  zone stay). Review fixes: one `limit_reauth` dependency (login bucket + route scope, fail closed) on deletion, export,
  link and unlink; link and unlink end the account's other sessions; pending-deletion refused under the lock; the
  `reauth` form and nonce survive `FEATURE_OAUTH=false`; dedicated notice text; `issued_at` required.
- Tests: link and unlink without re-auth refused; notice sent with the provider name only; Apple unlink revokes
  (5.8: the hook); replayed re-auth assertion refused; passwordless deletion, restore and export; consent withdrawal in
  the fallback; rate limits.
- Reviewers: `security-reviewer`, `code-reviewer`.

### 5.8 Apple and Google verifiers
- Every verifier fills `VerifiedIdentity.issued_at` (the `iat`; required, no default) and has a test that a stale `iat` fails
  re-auth (5.7). Apple unlink revoke goes into `IdentityService._revoke_provider_token` (TODO 5.8).
- `oauth/{jwks,apple,google,registry}.py`: cached JWKS refreshed once on an unknown `kid`; RS256/ES256 pinned; `aud`,
  `exp`/`iat`, `nonce == sha256(raw)` against the server nonce (ADR 0017 §3, `POST /v1/auth/oauth/nonce`, `GETDEL`), `email_verified`.
  Apple `iss` `https://appleid.apple.com`; Google `iss` `accounts.google.com` or `https://accounts.google.com` and
  `azp` = our client id. Replay: `on:` written with `SET NX` until `exp`; accepted only if the write succeeds; Redis
  down → 503 `provider_unreachable` for sign-in, sign-up, link and re-auth.
- Apple: server-side code exchange with an ES256 client secret read from a `_FILE` path, at most 6 months old
  (generated per call or cached for less); refresh token stored encrypted in `provider_refresh_token_enc` with the
  keyring (purpose `pillpal-oauth-refresh/v1`, salt = identity id, ADR 0016 §9), revoked after the deletion request
  commits (best effort, one retry), column cleared. Unlink revokes the same way.
- Tests through MockTransport: good token, wrong `aud`/`iss`/`azp`/`nonce`, nonce of another purpose, expired, unknown
  `kid`, `alg=none`/HS256, replay (`SET NX` race: one winner), Redis down → 503, exchange and revoke, revoke failure
  does not fail deletion, client secret age, no token in logs.
- Reviewers: `security-reviewer`, `code-reviewer`.
- **Done in 5.8 (no migration).** `oauth/{jwks,idtoken,apple,google,apple_tokens}.py`; `ProviderRegistry` builds the real
  verifiers (Apple when `OAUTH_APPLE_CLIENT_ID` is set, Google per platform) and owns the one `httpx` client (timeout
  `OAUTH_HTTP_TIMEOUT_SECONDS`, no redirects); the fake stays for dev and test and only stands in for an unconfigured
  provider. Google: `aud` = `OAUTH_GOOGLE_SERVER_CLIENT_ID` (web client) and a required `azp` = the platform client id
  (`OAUTH_GOOGLE_CLIENT_ID` Android, new `OAUTH_GOOGLE_IOS_CLIENT_ID`); a platform without an id is not offered; strict
  needs the server and the Android id together. New knobs: `OAUTH_JWKS_CACHE_SECONDS`, `OAUTH_JWKS_REFRESH_COOLDOWN_SECONDS`
  (an unknown `kid` refetches at most once per cooldown, so random `kid`s cannot amplify requests),
  `OAUTH_CLOCK_SKEW_SECONDS`, `OAUTH_APPLE_CLIENT_SECRET_TTL_SECONDS` (at most 6 months; cached until half spent).
  `exp` is strict (no leeway: the replay TTL needs a positive lifetime); `iat` may lead `now` by the skew;
  `VerifiedIdentity.issued_at` = `iat` and tests prove a stale `iat` is returned as such for the 5.7 freshness check.
  Apple code exchange: optional `authorization_code` on `POST /v1/auth/oauth/apple/sign-in` and `POST /v1/me/identities`;
  the answer's ID-token `sub` must equal the verified subject, else the token is dropped. A new account carries the
  sealed token through the sign-up ticket (`identity_id`, `refresh_token_enc`); a known identity without one stores it on
  the next sign-in with a code (not while pending deletion). The e-mail fallback path stores none. Exchange failures
  never fail a sign-in. Review fixes: `DELETE /v1/me` no longer calls Apple; the worker cron `revoke_provider_tokens`
  (every 5 min) revokes for accounts pending deletion and clears the column only on success, the erase job tries once
  more before deleting the rows; unlink revokes inline (3 s, no retry; the row is gone, so a failure is final). JWKS
  failures are remembered for the cooldown (min 5 s), the previous keys serve 24 h of outage, answers are size-bounded,
  non-`sig` keys skipped. No connection is held during Apple calls; discarded tokens (already linked, lost race, pending,
  e-mail fallback) are revoked; an abandoned sign-up token is accepted (ADR 0017 section 9). The Apple key is parsed once
  (strict refuses a broken one) and signing runs in a thread. Strict environments with Apple need `DATA_ENCRYPTION_KEYS`.

### 5.9 VK ID and Yandex ID
- **Done in 5.9 (no migration).** `oauth/{vk_id,yandex_id,code_http}.py`, details and the e-mail finding in ADR 0017 §3
  "As built (5.9)". `device_id` (VK) is an optional field of sign-in, link and the re-auth form; `OAUTH_VK_REDIRECT_URI`
  is new (default VK's Android URI, a strict setup refuses it without the client id). VK and Yandex e-mail never counts
  as verified (fallback always). The 5.8 re-check LOW is fixed in `services/provider_tokens.py` (keyset-paged sweep,
  unusable blob dropped); the unlink best-effort choice is recorded in ADR 0017 §9.
- Every verifier fills `VerifiedIdentity.issued_at` (now, for a code exchanged just now; required) and has a test per
  provider that re-auth accepts it only inside `OAUTH_REAUTH_MAX_AGE_SECONDS` (5.7).
- `oauth/{vk_id,yandex_id}.py`: the server takes only the authorization code and PKCE verifier from the client and
  exchanges them itself; a client-sent access token is never accepted. Client secrets with `_FILE` variants. VK e-mail
  counts as verified only if the provider docs say so, else the 5.6 fallback (Q7). Re-auth "fresh" = a single-use
  code exchanged immediately (ADR 0017 §8).
- Tests: happy, provider errors 401, timeout 503 `provider_unreachable`, client access token refused, code reuse
  refused, missing e-mail fallback, EU refuses the settings, no code or token in logs.
- Reviewers: `security-reviewer`, `code-reviewer`.

### 5.10 Payments backend (`0023_purchases`)
- `purchases (id, user_id fk CASCADE, store CHECK IN ('app_store','rustore','google_play'), product_id,
  original_transaction_id, environment CHECK IN ('production','sandbox'), purchased_at, verified_at, revoked_at null,
  UNIQUE (store, original_transaction_id))`; raw JWS or token never stored; personal, export rows, erased.
- `payments/{base,storekit,rustore,play,registry}.py`, pinned `AppleRootCA-G3.cer`. Registry per region (ADR 0018 §6):
  RU `rustore`, `app_store`; EU `app_store`, `google_play`; any other pair refused at startup.
- Settings: `FEATURE_PAYMENTS=false`, `PAYMENTS_PRODUCTS` (Q2: the remove-ads product grants `ads_removed` +
  `limits_lifted`), `PAYMENTS_APPLE_BUNDLE_ID`, `PAYMENTS_APPLE_APP_ID`, `PAYMENTS_ALLOW_SANDBOX` (refused in prod),
  `PAYMENTS_APPLE_ROOT_CERT_PATH` (refused in strict), `PAYMENTS_APP_ACCOUNT_KEY` (32 random bytes, base64, per
  region, distinct from other keys), `PAYMENTS_MAX_BODY_BYTES` (16 KiB); strict: `FEATURE_SOFT_LIMITS=true` requires
  `FEATURE_PAYMENTS=true`.
- `app_account_token` = HMAC-SHA256 of `user_id` with `PAYMENTS_APP_ACCOUNT_KEY`, returned by `GET /v1/me/entitlements`
  (additive field).
- StoreKit 2: x5c chain to the pinned root, marker OIDs, ES256, `bundleId`, product allowlist, `type` =
  `Non-Consumable`, `inAppOwnershipType` ≠ `FAMILY_SHARED`, `environment` ∈ {Production, Sandbox} (`Xcode` invalid;
  sandbox only with `PAYMENTS_ALLOW_SANDBOX`), `appAccountToken` equal to the caller's (missing or different →
  `invalid_purchase`), no `revocationDate`; `original_transaction_id` deduplicates. No OCSP: a revoked Apple
  intermediate is not detected (recorded as accepted).
- `POST /v1/me/purchases` → 201 entitlements; replay 200; other account 409 `purchase_already_claimed`; invalid 400
  `invalid_purchase`; stub store 503 `store_unavailable`; flag off 403; rate limit and `PAYMENTS_MAX_BODY_BYTES`
  (oversize → 413). Soft limits skip the relatives limit with
  `limits_lifted`.
- Tests: each StoreKit check on its own (wrong `appAccountToken`, consumable type, family-shared, Xcode environment,
  sandbox refused in prod), dedup per store, registry refuses other pairs at startup, rate limit, body limit,
  `app_account_token` stable per account.
- Reviewers: `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`.
- **As built** (details the plan left open): `PAYMENTS_PRODUCTS` is JSON `{store product id: "remove_ads"}`;
  `PAYMENTS_STORES` (optional JSON list) narrows the region's stores and refuses any other pair at startup; the
  request body is `{store, signed_transaction}` for `app_store` and `{store, purchase_token}` for the stubs; a store
  the region does not offer is `invalid_purchase`; chain validity is judged at the transaction's `signedDate`
  (Apple leaf certificates are short lived); the body limit is a pure ASGI middleware (FastAPI reads the body before
  dependencies); `PAYMENTS_RATE_LIMIT_ATTEMPTS` and `PAYMENTS_RATE_LIMIT_WINDOW_SECONDS` configure the per-account
  limit; `app_account_token` is `null` while `PAYMENTS_APP_ACCOUNT_KEY` is unset. `GET /v1/me/features` still reports
  the relatives limit regardless of `limits_lifted`: the app reads the entitlements (A2).

### 5.11 Consents required at registration
- Staging: flips the `CONSENT_REQUIRED_AT_REGISTRATION` default to true after A1 has shipped to staging. Prod is already
  forced true from its first deployment (5.2a). Dev stays optional. Reviewer: `code-reviewer`.
- Done (2026-11-11): staging defaults to true when unset (`config.py` `_prod_requires_consents`); an explicit
  `false` is still accepted there for an old field-test build.

### 5.12 *(optional)* Remote config
- `GET /v1/config?platform=` (authenticated, ETag) from a validated `REMOTE_CONFIG_ADS`; placements only on the
  allowlist of ADR 0018 §2 (`settings`, `about`). The validator and test reject every other screen name (reminder,
  dose, today, medication, history, relatives, reports, catalog, scan, consent, export, privacy), using the same list
  as the A2 client.
- Reviewers: `code-reviewer`, `privacy-compliance-reviewer`.

### 5.13 *(optional)* Backend Sentry wiring and docs sync
- Done: `sentry-sdk` initialized only with `SENTRY_DSN` (API and worker), `send_default_pii=False`, no local
  variables, bodies, breadcrumbs or trace headers, exception text dropped, tracing refused in staging/prod, RU
  refuses sentry.io (self-hosted per region, a processor in ADR 0017 section 11); docs sync (README,
  `.env.example`, `docs/staging.md`, CLAUDE.md).
- Reviewers: `security-reviewer`, `privacy-compliance-reviewer`.

### R10 Names and relatives (owner redesign, before A1)
Relatives see a person by the `display_name` of their `self` profile (invites, grants); until now the server
stored the default "Me" because the app never asked.
- PR1 (`feat/names-at-signup`): e-mail registration and OAuth sign-up require `display_name` (`PersonName`:
  trimmed, 2–20 code points, no control characters including tab and line breaks, not unique). Required in the
  schema without a compatibility flag: only field-test APKs exist, an old APK gets 422 `validation_error`. The
  "Me" default is gone. The name is validated before the address is looked up, so the register answer still
  reveals nothing about the address.
- A rename of the `self` profile (sync push upsert or `PATCH /v1/profiles/{id}`) that changes the name must pass
  `PersonName` (sync: `rejected`/`validation_error`; REST: 422); an unchanged legacy value passes other edits;
  managed profiles keep `DisplayName` (1–100).
- App: «Как вас зовут» on registration step 1 (hint «Это имя увидят ваши близкие»), Settings -> Account
  «Ваше имя» (local write of the `self` profile, outbox, sync), the same rule on the device, RU + EN.
- Test callers that register send a synthetic name (`tests/helpers.py`, `test_e2e/device.dart`,
  `integration_test` auth steps, `relatives_host.py`).
- Reviewers: `security-reviewer`, `offline-sync-reviewer`, `ui-consistency-reviewer`, `code-reviewer`.
- Next PRs of R10 (relatives screens) follow the owner's redesign brief.

### A1 App: consent, re-consent gate, privacy settings, export
- Consent screen at registration (separate health-data checkbox), registration sends `consents`, privacy section in
  Settings (list, withdraw contribution, withdraw health data → deletion dialog), export (request, poll, download to an
  app-private file excluded from backups, share, delete after sharing), RU + EN.
- Re-consent gate when `missing` is not empty (Q3): blocking screen until the kinds are recorded. While `missing`
  contains `health_data`, the app does not push or pull medical entities (medications, schedules, dose events); local
  reminders keep firing from local data; sync resumes after `POST /v1/me/consents` succeeds (ADR 0016 §5). The server
  does not refuse anything for it.
- Export requests show the step-up re-auth (password or provider assertion); the download is a single attempt, and a
  failed transfer means requesting a new export.
- `test_e2e/` helpers send consents; the onboarding emulator phase ticks the checkboxes.
- Reviewers: `ui-consistency-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`.

### A2 App: entitlements and promo
- Per-account cache refreshed on sign-in and daily, last value kept for 14 days on failure, cleared on sign-out;
  promo redeem sheet; pure `adsAllowedProvider(screen)` with an allowlist of named non-medical screens (`settings`,
  `about`); every other screen is false, including relatives' Family and day views, reports and PDF, scan, consent,
  export and privacy settings; also false with `ads_removed`; no ad SDK (ADR 0018 §2).
- Reviewers: `ui-consistency-reviewer`, `code-reviewer`.

### A3 *(optional)* Analytics event allowlist
- `docs/spec/analytics-events.md`, typed events, no-op sink; tests keep payload keys inside the allowlist and forbid
  medical fields, ids, gtin, product ids, `q` and catalog/scan events.

### A4 *(optional)* Region selection and remote config read
- Locale-based suggestion with confirmation, base URLs per region from dart-defines, reads `/v1/config`.

## Migrations and compatibility
- Seven create-table revisions, each reversible; no rewrite of existing tables; `users` unchanged (sentinel hash).
- Up/down round-trip plus `test_single_head` for each.
- All API changes are additive; `DELETE /v1/me` keeps the password form; field-test clients keep working until 5.11.
  Exception (R10, owner decision): `display_name` became required at registration and OAuth sign-up, so a
  field-test APK older than R10 cannot register (422); signed-in old clients keep working.
- Rule `v`, occurrence keys and vectors untouched.

## Privacy and region impact
- New personal tables, each with erasure and an export decision: `consents`, `entitlements`, `promo_redemptions`,
  `admin_audit` (SET NULL on erasure), `data_exports` (medical, purged at 24 h, deleted on a deletion request),
  `auth_identities` (subject exported), `purchases`; `promo_codes` is `system`. New Redis keyspaces, hashed and
  TTL-bound: `ot:` (signup tickets, VK pending binding), `on:` (replay, `SET NX`), `oc:` (server nonces, 5.6).
- Admin audit: `admin_audit` operator columns (`actor`, `os_user`, `host`) are excluded from export and purged after
  `ADMIN_AUDIT_RETENTION_DAYS=365`.
- Never logged: promo codes, id tokens, authorization codes, PKCE verifiers, nonces, signup tickets, signed
  transactions, purchase tokens; the admin CLI reads e-mails from stdin and audits account ids only.
- Regions: sign-in providers Apple/Google EU only, VK/Yandex RU only, RuStore Pay RU only; stores per region as in
  ADR 0018 §6; codes, keys (keyring, `PAYMENTS_APP_ACCOUNT_KEY`) and exports per region; the export never leaves the
  region except as the user's own download; third parties per region updated in ADR 0017/0018.
- Backups holding encrypted exports or erased accounts' data: a retention decision is required before the first prod
  deployment (ADR 0016 Negative).
- No ads yet; the gate and the remote-config validator forbid reminder, dose and medical screens.

## Done when
- [ ] Backend gates (`ruff`, format, `mypy app`, `pytest --cov=app --cov-fail-under=85`, `alembic upgrade head`, a
  `downgrade -1` round-trip, `test_single_head`) green per milestone.
- [ ] `spec/openapi.json` refreshed for every route change; vectors unchanged and valid.
- [ ] `backend.yml` green; for A1–A4 also `app.yml` (with `e2e`) and `app-emulator.yml`.
- [ ] Every new table in `TABLE_CLASSIFICATION` with erasure and an explicit export decision.
- [ ] Every new endpoint tested for happy path, 422, 401, foreign → 404, idempotent replay and rate limit.
- [ ] Every flag off by default; strict-environment refusals tested.

## Review log (2026-11-10, ADRs 0016–0018)

Accepted findings of the privacy and security review, applied in place in ADRs 0016–0018 and in the milestones above.
Entries are keyed by the ADR section they change; reviewer finding ids are not recorded here.

- ADR 0016 §5: the app pauses medical sync (medications, schedules, dose events) while `health_data` is missing; local
  reminders keep firing; the server refuses nothing (5.2a, A1).
- ADR 0016 §3: `ENVIRONMENT=prod` forces `CONSENT_REQUIRED_AT_REGISTRATION=true`; the optional window is dev and staging
  only (5.2a, 5.11).
- ADR 0016 §4: a deletion request stamps `withdrawn_at` on active `health_data`, `terms`, `privacy`; a restore leaves
  `missing` non-empty, so the gate runs before medical sync (5.2a).
- ADR 0016 §8: session binding through the access-token `sid` (= `family_id`) replaces `X-Device-ID` (5.5).
- ADR 0016 §8: `POST /v1/me/export` requires step-up re-auth and mails a notice without data (5.5).
- ADR 0016 §8: download is one atomic claim (`status='downloaded'`, archive nulled) with `RETURNING`; a transfer failure
  after the commit loses the export (5.5).
- ADR 0016 §8: cooldown ignores `downloaded` rows; per-user rate limits on status and download; `error_code` CHECK;
  `Content-Disposition` filename; POST rationale (5.5).
- ADR 0016 §9: keyring `DATA_ENCRYPTION_KEYS` with 32-byte keys checked at startup; blob layout; AAD; HKDF salt and info
  per purpose; rotation (5.5, 5.8).
- ADR 0016 §1: consent versions per region; a version covers all locales (5.2a).
- ADR 0016 §7: export decisions for `data_exports`, `promo_codes`; `auth_identities.subject` exported; `admin_audit`
  operator columns excluded (5.2a, 5.3, 5.5, 5.6).
- ADR 0016 Negative: backup retention is a pre-prod gate (Follow-ups; Privacy impact).
- ADR 0016 §10: legal items added (152-FZ art. 9, 10, 14, 15; managed profiles; EU to US transfers; purchase retention).
- ADR 0017 §2: `subject` exported as the account's own id; the API still hides it (5.6).
- ADR 0017 §3, §8: server nonce endpoint with purpose binding, `GETDEL`, 300 s TTL; replay via `SET NX`; Redis down →
  503 `provider_unreachable` (5.6, 5.8).
- ADR 0017 §3: Google `azp` and both `iss` forms; VK and Yandex take only code and verifier, never a client access
  token; re-auth "fresh" = single-use code exchanged at once (5.8, 5.9).
- ADR 0017 §3: rate limits on sign-in, sign-up, nonce, link, re-auth (5.6).
- ADR 0017 §4, §5: only verified accounts count as existing; a verified provider sign-up replaces an unverified
  password-only row; VK pending identity bound to `(email, provider, subject)` in Redis with the code TTL (5.6).
- ADR 0017 §5: body validated before `GETDEL`; ticket bound to region and platform; body region must equal `REGION`
  (5.6).
- ADR 0017 §6: link and unlink require re-auth and mail a notice (done in 5.7); the Apple unlink revoke is the 5.8 hook.
- ADR 0017 §7: sentinel recognised before the Argon2 parser and `needs_rehash`; timing test (5.6).
- ADR 0017 §9: ES256 key via `_FILE`; client secret at most 6 months; refresh-token keyring purpose and salt (5.8).
- ADR 0017 §10: Sentry SDK settings when 5.13 lands (5.13).
- ADR 0018 §2, §8: ads allowlist (`settings`, `about`) shared by A2 and the 5.12 validator (A2, 5.12).
- ADR 0018 §3: normalisation checks ASCII before uppercasing; lookup by UNIQUE digest; 32-byte base64 key (5.4).
- ADR 0018 §4: breaker is alert-only and blocks only callers with a failure today; explicit redeem outcomes;
  `INCR`/`EXPIRE` before the response (5.4).
- ADR 0018 §5: `object_id` is never a user id; erasure nulls it; `os_user` and `host` recorded; `ADMIN_AUDIT_RETENTION_DAYS`;
  CLI only through `docker compose exec` or `run --rm`; `--count` capped (5.3).
- ADR 0018 §6: `original_transaction_id`; `appAccountToken`; `type`, `FAMILY_SHARED`, `Xcode` checks; OCSP gap recorded;
  rate limit and body limit; stores per region (5.10).
- LOW, applied: 0016 §5 legal reference corrected to §10; 0016 follow-up on the 5.1 export of `refresh_tokens` removed
  (already done in `docs/spec/export.md`); 5.6 "provider unavailable → 404" split into 404 (not configured) and 503
  (provider or Redis down); 5.11 split into staging and prod.
- ADR 0015 §4, ADR 0016 §4 (5.2b): only the profile owner can grant the contribution consent; a co-guardian can clear it
  (owner decision 2026-11-10); a stale offline grant after a withdrawal is ignored; published links stay in the catalog.
- Follow-up (R7b review, backend task; done in `fix/auth-mail-background`, `BackgroundTasks`, see `backend/README.md`): send the password-reset and verification mail outside the request (ARQ or
  BackgroundTasks) so `/password-reset/request` and `/verify-email/resend` answer 202 in constant time for known and
  unknown addresses.
- Accepted residual (PR #95 review): the OAuth fallback sign-up (`oauth_sign_in.py`, e-mail entry) still creates the account or mails its notice inside the request, a timing oracle for known addresses. Each probe needs a fresh provider sign-in and gives one probe per address; follow-up: move it into the same mail job.
