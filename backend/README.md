# PillPal backend

FastAPI service for PillPal. One codebase, deployed once per data region
(`REGION=ru` or `REGION=eu`). Each stand serves only accounts of its own region.
Spec: `docs/TZ.md` §3, §4.1–4.3. Schedule rules: `docs/spec/schedule.md`.

Stack: Python ≥ 3.12, FastAPI, SQLAlchemy 2 (async) + asyncpg, Alembic,
PostgreSQL 16, Redis, ARQ (worker), httpx (push providers), aiosmtplib (e-mail), pydantic v2, Argon2id, PyJWT, structlog. Dependencies are
managed with [uv](https://docs.astral.sh/uv/).

## Run locally

```bash
cd backend
uv sync                                   # create .venv from uv.lock
redis-server --daemonize yes              # or docker run -p 6379:6379 redis:7
createdb -h localhost -U postgres pillpal # PostgreSQL 16 on :5432

export REGION=ru
export DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal
export REDIS_URL=redis://localhost:6379/0
export JWT_SECRET=$(python -c 'import secrets; print(secrets.token_urlsafe(48))')
export LOG_EMAIL_CODES=true               # dev only: print verification codes (forbidden in prod)

uv run alembic upgrade head
uv run uvicorn app.main:app --reload --no-access-log
```

- OpenAPI: <http://localhost:8000/docs> (JSON at `/openapi.json`)
- Liveness: `GET /healthz` (process only). Readiness: `GET /readyz` (DB + Redis, 503 otherwise).
- Behind a reverse proxy, add `--proxy-headers --forwarded-allow-ips=<proxy ip>`
  so rate limiting sees the real client IP.

## E-mail

`app/email.py` defines the `EmailSender` protocol and the dev senders; `app/email_smtp.py` is the
real one (`aiosmtplib`, implicit TLS or STARTTLS, timeouts, optional login); `app/email_templates.py`
renders the plain-text mails, Russian then English in one body, for every kind (verification, password
reset, restore code, "account exists", deletion requested, restored, pending deletion). A mail names
no medication or schedule, its subject is neutral and a code appears in the body only. Addresses,
codes and passwords are never logged; a failed send logs `smtp_send_failed` with the exception class
and raises `EmailDeliveryError`, which `AuthService` swallows (same response with or without a
working provider: no account enumeration). Tests run a real SMTP server in-process (`aiosmtpd`,
`tests/smtp_helpers.py`) with TLS, STARTTLS and login.

## Staging

`ENVIRONMENT=staging` is the personal field-test stand: same safety rules as `prod`. The compose
stack, the manual deploy workflow and the owner guide are in `infra/staging/` and `docs/staging.md`.

## Configuration

| Variable | Required | Default | Notes |
|---|---|---|---|
| `REGION` | yes | — | `ru` or `eu` |
| `ENVIRONMENT` | no | `dev` | `dev`, `test`, `staging` or `prod`. `staging` and `prod` forbid `LOG_EMAIL_CODES=true`, refuse a half-configured push provider and refuse to start unless `EMAIL_BACKEND=smtp` (the log and memory senders drop every code); `prod` also rejects debug certificates in `ANDROID_CERT_SHA256S`. Staging deployment: `docs/staging.md` |
| `DATABASE_URL` | yes | — | `postgresql://` is rewritten to `postgresql+asyncpg://` |
| `JWT_SECRET` | yes | — | ≥ 32 chars; also keys the e-mail code HMAC |
| `REDIS_URL` | no | `redis://localhost:6379/0` | rate limiting and the ARQ queue; in production with a password: `redis://:password@host:6379/0` (Redis is never exposed publicly) |
| `ACCESS_TOKEN_TTL_SECONDS` | no | `900` | access JWT lifetime (15 min) |
| `REFRESH_TOKEN_TTL_SECONDS` | no | `2592000` | 30 days |
| `REFRESH_REUSE_WINDOW_SECONDS` | no | `120` | a repeated rotation of the same old refresh token from the same device within this window returns the same pair, once (Redis, encrypted, GETDEL); later or from another device it is reuse and revokes the family |
| `EMAIL_CODE_TTL_SECONDS` | no | `900` | 6-digit codes |
| `EMAIL_CODE_MAX_ATTEMPTS` | no | `5` | wrong attempts per code |
| `EMAIL_CODE_WINDOW_SECONDS` | no | `86400` | window for the two limits below |
| `EMAIL_CODE_DAILY_CAP` | no | `5` | codes issued per account and purpose per window (further requests answer the same but send nothing) |
| `EMAIL_CODE_MAX_FAILED_PER_WINDOW` | no | `10` | wrong guesses per account and purpose per window, summed over all codes (a new code does not reset it) |
| `LOG_EMAIL_CODES` | no | `false` | dev only; rejected when `ENVIRONMENT=staging` or `prod` |
| `EMAIL_BACKEND` | no | `log` | `log` (drops the mail, logs an event), `memory` (tests) or `smtp`; `staging`/`prod` need `smtp` |
| `SMTP_HOST`, `SMTP_FROM` | with `smtp` | — | provider host; sender as `address` or `Name <address>` (must be the mailbox for most providers) |
| `SMTP_SECURITY` | no | `ssl` | `ssl` (implicit TLS) or `starttls` (required, never downgraded to plain text) |
| `SMTP_PORT` | no | 465 / 587 | by `SMTP_SECURITY` |
| `SMTP_USERNAME`, `SMTP_PASSWORD` or `SMTP_PASSWORD_FILE` | together | — | both or neither; the file variant is for Docker secrets; never logged |
| `SMTP_TIMEOUT_SECONDS` | no | `10` | connect, TLS and command timeout; a failed send never changes the HTTP response |
| `RATE_LIMIT_AUTH_MAX_ATTEMPTS` | no | `10` | per (IP, e-mail) and per e-mail across all IPs, per window |
| `RATE_LIMIT_AUTH_WINDOW_SECONDS` | no | `900` | fixed window |
| `RATE_LIMIT_IP_MULTIPLIER` | no | `10` | per-IP bucket = max × multiplier |
| `PASSWORD_HASH_TIME_COST` / `_MEMORY_KIB` / `_PARALLELISM` | no | `3` / `65536` / `4` | Argon2id |
| `DB_POOL_SIZE` | no | `10` | |
| `LOG_LEVEL` | no | `INFO` | |
| `CORS_ORIGINS` | no | `[]` | JSON list; CORS is off when empty (mobile clients need none) |
| `INVITE_TTL_SECONDS` | no | `604800` | invite lifetime (7 days) |
| `GUARDIAN_INVITE_TTL_SECONDS` | no | `86400` | guardian invites live 24 h: they grant full access |
| `INVITE_REPLAY_WINDOW_SECONDS` | no | `86400` | how long a consumed invite remembers its accepter (`cleanup_retention` clears it) |
| `SUPPORTED_DISCLOSURE_VERSIONS` | no | `[1]` | JSON list of invite disclosure-screen versions; others are 422 |
| `MAX_ACTIVE_INVITES_PER_PROFILE` | no | `5` | open invites per profile (409 `too_many_invites`) |
| `MAX_ACCESS_SCOPES_PER_USER` | no | `100` | profiles one account may reach: own, managed and granted (409 `too_many_scopes` on accept and on creating a managed profile, REST and sync) |
| `DEVICE_TOUCH_INTERVAL_SECONDS` | no | `300` | a scoped pull rewrites the device's last-seen time at most this often |
| `MAX_DEVICES_PER_USER` / `DEVICE_STALE_AFTER_DAYS` | no | `50` / `90` | `X-Device-ID` is client-chosen: a new id over the cap is 409 `too_many_devices`, after devices unseen for the stale period are forgotten (the cap is soft under concurrency) |
| `GRANTS_LIST_LIMIT` | no | `500` | rows per direction in `GET /grants` |
| `FEATURE_SOFT_LIMITS` | no | `false` | soft limits stay off until payments exist |
| `SOFT_LIMIT_RELATIVES` / `SOFT_LIMIT_PDF_REPORTS` | no | `3` / `3` | only with the flag on |
| `PUBLIC_LINK_BASE_URL` | no | `https://links-<region>.pillpal.invalid` | bare https origin of invite links `…/i#<token>`; the `.invalid` placeholder never resolves (owner decision D6) |
| `ANDROID_PACKAGE_NAME`, `ANDROID_CERT_SHA256S` | no | unset | `assetlinks.json` (404 until both are set); fingerprints are `AA:BB:…` (32 bytes), JSON list |
| `ANDROID_DEBUG_CERT_SHA256S` | no | `[]` | debug-keystore fingerprints (per machine); `prod` refuses to start when one is also in `ANDROID_CERT_SHA256S` |
| `APPLE_TEAM_ID`, `IOS_BUNDLE_ID` | no | unset | `apple-app-site-association` (404 until both are set) |
| `WELL_KNOWN_CACHE_SECONDS` | no | `3600` | `Cache-Control` of the two verification files |
| `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON` / `_FILE` | no | unset | FCM push (HTTP v1). The service account of this region with `roles/firebasecloudmessaging.admin` only; the key may come from a Docker secret via `_FILE` |
| `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_TOPIC`, `APNS_PRIVATE_KEY` / `_FILE` | no | unset | APNs push (HTTP/2, ES256 `.p8`). One key per region; `APNS_TOPIC` is the bundle id |
| `RUSTORE_PROJECT_ID`, `RUSTORE_SERVICE_TOKEN` / `_FILE` | no | unset | RuStore push, **RU only**: any `RUSTORE_*` with `REGION=eu` fails startup |
| `PUSH_MAX_ATTEMPTS` | no | `5` | delivery attempts before a push is dropped |
| `PUSH_STALE_AFTER_SECONDS` | no | `7200` | a push older than this is dropped, and it is also the provider TTL |
| `PUSH_MAX_TOKENS_PER_USER` | no | `10` | registered push tokens per account (409 `too_many_push_tokens`) |
| `PUSH_BATCH_SIZE` / `PUSH_SEND_CONCURRENCY` / `PUSH_SEND_TIMEOUT_SECONDS` | no | `200` / `20` / `10` | rows claimed per batch, parallel sends, per-request provider timeout |
| `PUSH_CLAIM_LEASE_SECONDS` | no | `360` | a claimed row is retried after this long if the worker died before recording the result; startup requires it to exceed `ceil(PUSH_BATCH_SIZE / PUSH_SEND_CONCURRENCY) x 3 x PUSH_SEND_TIMEOUT_SECONDS + 30` |
| `PUSH_RUN_LOCK_SECONDS` | no | `600` | TTL of the Redis lock that keeps one `deliver_pushes` run at a time (a run that finds it held is skipped) |
| `PUSH_RETRY_BACKOFF_SECONDS` | no | `[30, 120, 600, 1800]` | back-off between attempts (a longer `Retry-After` wins, capped at the staleness window) |
| `PUSH_MAX_BATCHES_PER_RUN` | no | `10` | batches per `deliver_pushes` run; the 10 s cron continues a backlog |
| `PUSH_SENT_RETENTION_HOURS` / `PUSH_OUTBOX_RETENTION_DAYS` / `PUSH_TOKEN_STALE_DAYS` | no | `24` / `7` / `270` | retention of sent outbox rows, of every outbox row, and of tokens without a success |
| `DETECTOR_ENABLED` | no | `false` | the detector cron does nothing unless true; **do not enable in production before milestone 3.6** (zones, D4) |
| `DETECTOR_MAX_WINDOW_SECONDS` | no | `600` | longest span one detector tick looks at (a backlog is caught up over several ticks) |
| `DETECTOR_MAX_CATCHUP_SECONDS` | no | `21600` | after longer downtime the detector skips ahead to this far behind now (the skipped seconds are logged); also the age limit for alerting a late undo; must be at least the window |
| `DETECTOR_PROFILE_BATCH` | no | `500` | eligible profiles per detector batch (one transaction, one advisory lock per owner); at most 1000. PostgreSQL's `max_locks_per_transaction` (default 64, the lock table is shared across `max_connections`) must leave room for it |
| `DETECTOR_LOCK_TIMEOUT_MS` | no | `5000` | a batch that cannot get its journal locks this long fails the tick; the window replays |
| `DETECTOR_SKEW_MARGIN_SECONDS` | no | `120` | undos are read this far before the window (writer clock skew) |
| `DETECTOR_ALERT_RETENTION_HOURS` | no | `72` | alerts are deleted this long after detection; startup requires it to cover the catch-up plus `PUSH_STALE_AFTER_SECONDS` |

A provider with all its settings is enabled; with none it is disabled (its pushes are
dropped with `provider_disabled`). A provider that is only partly configured fails startup
when `ENVIRONMENT=prod`. Every `*_FILE` variable is read once at startup and must not be set
together with its inline twin.

## Tests and checks

Tests use a **real** PostgreSQL and Redis (no SQLite, no DB mocks). The suite
drops and recreates the `public` schema of the test database and runs the
Alembic migrations once per session; each test truncates tables and flushes
the Redis DB. One test also creates/drops a scratch database
`pillpal_test_migrations` to check upgrade → downgrade → upgrade.

```bash
export DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_test
export REDIS_URL=redis://localhost:6379/0   # this DB is FLUSHED by the tests (use a dedicated DB index)
export REGION=ru JWT_SECRET=test-secret-test-secret-test-secret

uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest --cov=app --cov-fail-under=85
```

`spec/openapi.json` is the API contract snapshot the Flutter client's contract
test reads (`app/test/data/contract_test.dart`). After changing a route or a
schema, regenerate it with `uv run python -m app.openapi_snapshot`;
`tests/test_openapi_snapshot.py` fails while it is stale. The per-entity sync
payloads (`ProfileData`, `MedicationData`, `ScheduleData`, `DoseEventData`)
are added to it explicitly because push `data` is free-form in the route schema.

`TEST_DATABASE_URL` / `TEST_REDIS_URL` override the URLs above for tests only.

## API overview (`/v1`)

All errors use one envelope: `{"error": {"code": "...", "message": "..."}}`
(422 adds `details: [{loc, msg}]`; input values are never echoed). Every
response carries `X-Request-ID` (client-supplied value is echoed if valid).

| Area | Endpoints |
|---|---|
| Auth | `POST /auth/register` (always 202 `{"status":"verification_sent"}`; `region` must match the server, else 409 `wrong_region`), `POST /auth/verify-email` `{email, code}` → token pair, `POST /auth/verify-email/resend` `{email}` (always 202), `POST /auth/login` (403 `email_not_verified` after a correct password; 403 `account_pending_deletion` with `details: {restore_ticket, erase_after}` for a pending account), `POST /auth/restore` `{restore_ticket, code}` → token pair (401 `invalid_token` for a bad, spent or expired ticket, a wrong or missing code, or after `erase_after`), `POST /auth/refresh`, `POST /auth/logout`, `POST /auth/password-reset/request`, `POST /auth/password-reset/confirm` |
| Me | `GET /me`, `DELETE /me` with body `{password}` (401 `invalid_password`; starts the deletion grace period, 204; the account is erased by the hourly job after `erase_after` unless restored) |
| Profiles | `GET/POST /profiles`, `GET/PATCH/DELETE /profiles/{id}` |
| Medications | `GET/POST /profiles/{id}/medications`, `GET/PATCH/DELETE /medications/{id}` |
| Schedules | `GET/POST /medications/{id}/schedules`, `GET/PATCH/DELETE /schedules/{id}` |
| Dose events | `POST /dose-events` (201 new, 200 identical replay, 409 different payload), `GET /dose-events?profile_id&medication_id&from&to&limit`, `GET /dose-events/{id}` |
| Sync | `POST /sync/push` and `POST /sync/pull` `{cursors: {profile_id: seq}, limit}` (header `X-Device-ID` required; 1–50 cursors, limit ≤ 500; scopes, per-scope cursors, role projection) |
| Invites | `POST /profiles/{id}/invites` `{id, role, disclosure_version}` → `{id, role, expires_at, url}` (the token is in `url`, shown once; 409 `already_exists` on a replayed id, 409 `too_many_invites`, 422 for `guardian` on a self profile), `GET /profiles/{id}/invites` (open invites, no token), `DELETE /profiles/{id}/invites/{invite_id}` (revoke; 204, idempotent; 409 `invite_used` once consumed). Owner only, others get 404 |
| Accepting | `POST /invites/preview` `{token}` → `{inviter_display_name, profile_display_name, profile_kind, role, expires_at}`; `POST /invites/accept` `{token}` → the grant (201; 200 for a replay by the same account). Errors: 404 `invite_invalid`, 410 `invite_expired`, 409 `invite_used` / `invite_own_profile` / `already_linked` (invite stays open) / `relatives_limit_reached` / `too_many_scopes`. Preview answers `invite_used` only to the account that used the link (others: `invite_invalid`). Rate limited per user and IP, as is invite creation |
| Grants | `GET /grants` → `{outgoing: [{…, active, disclosure_version}], incoming: [{…, notify_missed}]}`; `PATCH /grants/{id}` with exactly one change (owner: `role` plus `disclosure_version`, never `guardian`: 409 `guardian_requires_invite`; grantee: `notify_missed`; anything else 422, never partial); `DELETE /grants/{id}` (owner revokes, grantee leaves; a retry is 404) |
| Push tokens | `PUT /push-tokens/current` `{provider: fcm\|apns\|rustore, token, apns_environment?}` (header `X-Device-ID`; 200 `{provider, apns_environment, updated_at}`; 422 for a bad format or `apns_environment`; 409 `too_many_push_tokens`), `DELETE /push-tokens/current` (204, idempotent) |
| Features | `GET /me/features` → `{soft_limits_enabled, relatives_limit, pdf_reports_limit, account_deletion_grace_days, managed_archive_retention_days}` (limits `null` while the flag is off) |
| Links | `GET /.well-known/assetlinks.json`, `GET /.well-known/apple-app-site-association` (from Settings, 404 until configured, `application/json`, no redirects), `GET /i` (static landing page for browsers without the app) |

### Rules worth knowing

- **Ids** of profiles, medications, schedules and dose events are generated by
  the client (UUID). Creating an existing id → 409 `already_exists`.
- **Ownership** is enforced inside every SQL query; another user's id behaves
  exactly like a missing one (404).
- **Deletes are tombstones without content**: the row keeps its id, `version`
  and conflict key, but names, notes, stock fields, rules and profile display
  names are erased (CHECK constraints require content on live rows and its
  absence on tombstones). Deleting a profile or medication tombstones its
  children. `version` increments on every server-side change.
- **Account deletion has a grace period** (ADR 0010): `DELETE /me` (password) only marks the
  account `pending_deletion`: `erase_after = now + ACCOUNT_DELETION_GRACE_DAYS` minus two job
  intervals, refresh families revoked, `tokens_not_before` set, grants inactive in both
  directions, open invites revoked, managed profiles with an active co-guardian archived. The
  hourly job `app.jobs.account_erasure.erase_expired_accounts` then removes the user and every
  row it owns (profiles, medications, schedules, dose events, journal, devices, tokens, codes),
  one transaction per user; the address can register again afterwards.
- **Dose events are append-only** (DB trigger rejects UPDATE/DELETE). Corrections
  are `undo` events with `target_event_id`. The only exception is account
  erasure: the trigger lets DELETE (never UPDATE) through while
  `pillpal.purge = 'on'`, which only the erasure transaction sets (`SET LOCAL`).
- **Snoozes carry their due time**: a `snoozed` event stores `snooze_until`
  (migration `0002`, ADR 0001 §7), so every device and the missed-dose
  detector agree when the snoozed dose is due again.
- **Registration does not reveal accounts**: `register` answers the same for
  new and known addresses; a known address gets an "account already exists"
  e-mail instead of a code. Verifying the code is the first login. Unverified
  accounts cannot log in (they can still reset the password, which also
  verifies the address).
- **Auth**: Argon2id; access JWT (HS256, 15 min, bound to the region);
  opaque refresh tokens stored as SHA-256, single use with rotation; reuse of a
  rotated token revokes the whole token family (401 `token_reused`). A password
  reset revokes all refresh tokens and rejects access tokens whose `iat` is
  before `users.password_changed_at` (1 s granularity). Codes are 6 digits,
  HMAC-hashed, expire, are attempt-limited per code and per account (see
  config) and capped per day. Auth endpoints are rate limited in Redis per IP,
  per (IP, account) and per account across IPs (429 `rate_limited` +
  `Retry-After`); the limiter fails open if Redis is down.
- **Logs** never contain e-mail addresses (e-mail events log the user id) or
  raw request paths: the access log records the route template
  (`/v1/medications/{medication_id}`) or `<unmatched>`.

### Relatives (Phase 3, milestone 3.2)

ADRs 0005 and 0009. A *grant* gives another account `viewer`, `editor` or
`guardian` (managed profiles only) on one profile; it exists only because an
invite was accepted, and copies the invite's `disclosure_version` (what the owner
confirmed the relative would see). Database triggers enforce: one grant per
(profile, grantee); the grantee is never the owner (also when
`profiles.owner_user_id` changes); `guardian` only on managed profiles; no grant on
a tombstoned profile (insert and role change only, so `notify_missed` stays editable).

- **Invite tokens** are `secrets.token_urlsafe(32)`; only `sha256(token)` is stored.
  The link is `{PUBLIC_LINK_BASE_URL}/i#<token>`: the fragment is never sent to a
  server, and the token travels in JSON bodies, never in a URL or a log.
- **Accept** locks the invite row. A replay by the accepting account returns its
  grant only while the grant exists; otherwise `invite_used`. A consumed invite never
  creates a grant again, so a revoked relative cannot return with the old link.
- **Access service** (`app/services/access.py`): `role_for_profile`, the
  `accessible_profiles` / `accessible_scopes` SQL predicates and `has_full_access`.
  **Projection** (`app/domain/privacy.py`): pure functions for editor/viewer output,
  applied to every pull and to every `current` of a push result. **REST resource
  endpoints** (profiles, medications, schedules, dose events) are open to the owner and,
  on a managed profile, its guardians (200); editors and viewers get 404, they use sync
  only. A guardian cannot delete a profile (403 `forbidden`, only its owner can);
  invites and grants stay owner-only.
- **Inventory** (`app/services/personal_data.py`): every table and Redis keyspace is
  classified; a test fails on anything unclassified.
- Accepting an invite enqueues a `link_accepted` push for the owner, and a restore enqueues
  `link_restored` for the owners of the profiles the account holds grants on (see Push below).

### Account deletion grace, restore and managed archive (milestone 3.3b)
- **Login of a pending account** with the right password: `403 account_pending_deletion`,
  `details: {restore_ticket, erase_after}`, and a `restore_account` code is mailed. The ticket is
  a short-lived single-use bearer secret (Redis, hashed; Sentry-scrubbed). A wrong password
  looks like any other failure.
- **`POST /v1/auth/restore {restore_ticket, code}`**: needs both; restores the account, its
  grants and the profiles archived by this deletion, sets `tokens_not_before`, returns tokens
  and mails "account restored". Past `erase_after` or bad ticket/code: `401 invalid_token`.
- **Registration with a pending address** answers like any registration, creates nothing and
  mails instructions only.
- **Sync and grants:** pending owners and grantees count as revoked in scoped pull and
  `GET /grants` shows `active: false`. `granted_seq` is **not** bumped on restore: the history
  the relative could see before stays visible, so a client that kept its cursor continues from it
  and a client that dropped the scope backfills from 0.
- **Managed archive (D1):** every managed profile of a pending owner becomes a read-only
  archive (writes `read_only`, invites refused, no missed-dose detection); co-guardians
  may only leave, and a restore un-archives it. At the erasure ownership moves to the earliest active co-guardian
  (`owner_erased`), the archive is kept `MANAGED_ARCHIVE_RETENTION_DAYS`, any guardian may purge
  it earlier with `DELETE /profiles/{id}` (409 `read_only` while its new owner is pending); purge
  removes events and journal rows. Without an
  active co-guardian the profile is erased with its owner. The erased account's
  `updated_by_device` is nulled on rows in foreign profiles.
- **Jobs** (`app/jobs`, plain async functions, run by the ARQ worker, see "Push and the worker"):
  `erase_expired_accounts` (hourly; loops until nothing is due, logs `erasure_overdue_count`) and
  `cleanup_retention` (daily; clears `consumed_by_user_id` after `INVITE_REPLAY_WINDOW_SECONDS`,
  deletes invites `INVITE_RETENTION_DAYS` after their end of life, purges expired archives, deletes
  old push rows and stale tokens). Both can also be run once from a shell
  (`python -m app.jobs.account_erasure`, `python -m app.jobs.retention`; exit code 1 = failures).
  **A deployment needs the worker (or a cron calling these entry points)**: nothing else completes
  a deletion.
- **Settings:** `ACCOUNT_DELETION_GRACE_DAYS` (1..30, default 30), `ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS`,
  `ACCOUNT_ERASURE_BATCH_SIZE`, `ACCOUNT_ERASURE_RETRY_LOCK_TIMEOUT_SECONDS`,
  `ACCOUNT_RESTORE_TICKET_TTL_SECONDS`, `MANAGED_ARCHIVE_RETENTION_DAYS`.

### Push and the worker (milestone 3.4)
- **Providers** (`app/push/`): FCM (HTTP v1, service-account JWT, the OAuth token URL is
  hard-coded), APNs (HTTP/2, per-region `.p8` key) and RuStore (RU only), behind one `PushSender`
  protocol; `FakePushSender` for tests; `DisabledPushSender` for an unconfigured provider. A
  `PushPayload` holds ids and enums only (`v t a p m g s`); a CHECK on `push_outbox.payload` allows
  the same keys with id or enum values, so no medication name, dose or time can be queued or sent.
  Senders never log tokens, URLs or exception text (a transport error is a `RETRY` with the code
  `transport_error`; the `httpx` request log is silenced because the APNs URL contains the token).
- **Tokens:** `PUT /v1/push-tokens/current {provider, token, apns_environment?}` (header
  `X-Device-ID`; format per provider; at most `PUSH_MAX_TOKENS_PER_USER` per account; a token held
  by another account or device is reassigned in the same transaction) and
  `DELETE /v1/push-tokens/current`. The token is never returned. Logout deletes the token of the
  device bound to the refresh token, and a deletion request deletes all of the account's tokens.
  **Whether to register is the client's decision** (the app registers only while the user needs
  relative alerts, milestone 3.9); the server accepts any well-formed token within the limits.
  RuStore tokens are refused outside `REGION=ru`.
- **Outbox** (`push_outbox`): written in the transaction of the event (`link_accepted`,
  `link_restored`, `missed`, `resolved`), deduplicated by `dedupe_key`.
  `deliver_pushes` claims up to 200 due rows with `FOR UPDATE SKIP LOCKED` and **re-checks access in
  the claim query** (recipient and subject owner not pending deletion, profile live and not archived,
  recipient owns it or holds an active grant, a `hidden` medication only for owner and guardians);
  failing rows are `dropped/access_changed`. The claim moves `next_attempt_at` forward by a lease and
  counts the attempt, so no connection or lock is held while sending and a crashing row cannot loop.
  One run at a time (Redis lock `lock:push_delivery`), and a result is recorded only by the attempt that
  claimed the row (`attempts` fence), so a slow provider cannot cause double sends or overwrites.
  `link_*` rows are also dropped when their grant is no longer active.
  `OK` → `sent`; `INVALID_TOKEN` → the token is deleted (unless it changed or was re-registered meanwhile); `RETRY` → 30 s, 2 min, 10 min, 30 min (or `Retry-After`); `FATAL`, stale
  (`PUSH_STALE_AFTER_SECONDS`) or out of attempts → `dropped`. Delivery is at least once.
- **Worker:** `arq app.worker.WorkerSettings` (compose service `worker`, same image). Crons:
  `detect_missed_doses` every minute, `deliver_pushes` every 10 s, `erase_expired_accounts` hourly (:05), `cleanup_retention` daily
  (03:15 UTC). The retention query for `sent` rows (`status = 'sent' AND sent_at < …`) has no index on
  purpose: it is a daily job and the table is small (rows live at most 7 days); add a partial index if the
  outbox grows. Refresh-token reuse and a password reset delete the push tokens of the revoked sessions'
  devices. Jobs take no arguments, run in a wrapper that logs failures as exception type and
  frames only, keep no results (`keep_result=0`) and use a JSON serializer (never pickle). Redis
  must have a password and must not be exposed; the container health check is `arq --check`.
  `ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS` must stay `3600` (the worker refuses to start otherwise):
  the deletion deadline margin assumes the hourly cron.

### Missed-dose detector (milestone 3.5)
ADR 0007 is authoritative; this is what the code does.
- **Tick** (`app/services/missed_doses.py`, ARQ cron `detect_missed_doses` every minute, with an
  immediate `deliver_pushes` when something was queued): holds a session-level
  `pg_try_advisory_lock` on a dedicated connection for the whole tick (a second tick is skipped);
  looks at the window `[watermark, e)`, `e = min(now, watermark + DETECTOR_MAX_WINDOW_SECONDS)`;
  pages eligible profiles by id (`DETECTOR_PROFILE_BATCH`), one transaction per page; moves
  `detector_state.watermark` forward in the last transaction. A tick that fails leaves the
  watermark, so the window is retried; the alert insert is `ON CONFLICT DO NOTHING`.
  Downtime beyond `DETECTOR_MAX_CATCHUP_SECONDS` is skipped and logged once as
  `detector_gap_skipped` (`skipped_seconds`). After enabling `DETECTOR_ENABLED` following more than
  6 h with it off, a single `detector_gap_skipped` is expected.
- **Eligible profile:** live, not archived, owner not pending deletion, `missed_alerts_enabled`,
  and managed with an active co-guardian or with an active grant that has `notify_missed`.
  Eligibility is read again under the owners' journal locks, which a batch takes (sorted, one
  statement) before it reads any event.
- **Candidates** (`app/services/missed_batch.py`): A, occurrences the engine expands with
  `instant + grace` in the window (zone: `fixed_tz`, else `profiles.timezone`, docs/spec/schedule.md
  §3.1; occurrences before `schedules.created_at` are dropped); B, snoozes with
  `snooze_until + grace` in the window; C, targets of undos *recorded* in the window (a late undo;
  not older than the catch-up horizon). The decision is `domain.missed.alert_due_at` over
  `domain.dose_state`: unmarked and the final `due + grace` in the window (C: already behind us).
  Invalid rules and zones are skipped and logged by `schedule_id` and `error_code` only.
- **Recipients** (`app/domain/missed.py`, shared with resolution): the owner of a managed profile
  that has co-guardians; grantees with `notify_missed` whose grant was created at or before the
  final due time; `hidden` medications to owner and guardians only; a self owner never. Pending
  accounts have no active grants. One outbox row per recipient token (`missed`, ids only, `s: "u"`
  when `unconfirmed`: a self profile whose owner's devices were all last seen before the
  occurrence).
- **Payload `m`:** owner and guardians get the medication id; relatives get it only for `shared`
  medications. For `anonymous` ones relatives get `{v, t, a, p}` and the outbox row has no
  `subject_medication_id`, so the device shows a generic text (decision recorded in ADR 0008).
- **Resolution** (`app/services/missed_resolution.py`): `record_dose_event` (REST and sync push)
  sets `resolved_at` on the occurrence's alert for a `taken` / `skipped`, in the same transaction
  under the same owner lock, and queues `resolved` to recipients recomputed by the rule above.
  A `missed` is never re-sent.
- **`missed_alert_minutes` decrease:** lowering it can move an occurrence's `due + X` behind the
  watermark; that occurrence is never alerted (accepted, ADR 0007 §3). Raising it postpones
  alerts of occurrences not yet alerted. An alert already sent is not retracted by either.
- **Retention:** alerts 72 h (`cleanup_retention`). Erasure and archive purge delete them with the
  profile; the inventory classifies `missed_dose_alerts` (medical) and `detector_state` (system).

### Sync protocol

`POST /v1/sync/push` body: `{"mutations": [{entity, op, id, data, client_updated_at}]}`,
`entity ∈ profile|medication|schedule|dose_event`, `op ∈ upsert|delete`, at most
500 per batch. `data` is the entity's **full** state for upserts:

- profile: `{kind?: "managed"|"self", display_name, timezone}` (new profiles must be `managed`)
- medication: `{profile_id, name, form?, strength_text?, notes?, tz_mode, fixed_tz?, stock_count?, stock_unit?, low_stock_days?, privacy}`
- schedule: `{medication_id, rule}`
- dose_event: `{medication_id, type, at, occurrence_key?, target_event_id?, note?, snooze_until?}`
  (`snooze_until` is required for `snoozed` and forbidden otherwise; `at < snooze_until <= at + 24h`)

Server-controlled fields in `data` (`id`, `version`, `created_at`,
`updated_at`, `client_updated_at`, `updated_by_device`, `deleted_at`,
`owner_user_id`; for dose events also `profile_id`, `recorded_at`,
`device_id`) are ignored, so pulled state can be pushed back as is; any other
unknown field is a `validation_error`. Schedule ids (and the schedule id inside
an `occurrence_key`) must be canonical lowercase UUID strings; occurrence keys
must be exactly what the schedule engine builds (`<id>/YYYY-MM-DDTHH:MM`).

Each mutation runs in its own savepoint and gets a result
`{entity, id, status, code?, version?, current?}`:

- `applied` — stored, or an idempotent replay of an already stored write
  (same key and same payload);
- `ignored_stale` — the server has a newer write (last-write-wins on
  `(client_updated_at, X-Device-ID)`; equal timestamps → larger device id wins)
  or the entity is a tombstone (`code: "deleted"`; tombstones are terminal).
  `current` holds the server state to adopt (`{op, data, client_updated_at,
  updated_by_device, deleted_at}`);
- `rejected` — `code` ∈ `validation_error`, `parent_not_found`,
  `parent_deleted` (creating a child under a tombstoned parent),
  `key_conflict` (same `(client_updated_at, device)` key as the stored write
  but a different payload; `current` is set), `immutable_field` (moving an
  entity to another parent / changing `kind`), `invalid_kind`,
  `self_profile_protected`, `append_only`, `idempotency_conflict`,
  `invalid_undo_target`, `invalid_occurrence_key`, `already_exists` (id taken
  by someone else), `clock_skew` (> 10 min in the future; dose event `at`
  has the same bound).

**Deletes are final and always win**, whatever their timestamp: an edit and a
delete of the same entity end deleted in either arrival order. A delete (or a
cascade) never moves an entity's conflict key backwards. Children are created
under a parent read `FOR SHARE`, so a concurrent parent delete cannot leave a
live child behind.

**Clients must push their outbox in order** (a batch is applied in order). A
delete of an id the server has never seen is a no-op (`applied`), so if a
create and its later delete arrived reversed, the delete would do nothing and
the create would leave a live entity behind.

Every applied change appends to `sync_changes` (`seq BIGSERIAL`), keyed by the
**profile** it belongs to (the change's *scope*; FK `ON DELETE CASCADE`, index
`(profile_id, seq)`), with `op ∈ upsert|delete|privacy` (`privacy` is journal-only:
a medication's privacy level changed; it is never on the wire).

**Journal locks.** All writers of the scopes of one *owner* (the account in
`profiles.owner_user_id`) hold that owner's advisory lock (`pg_advisory_xact_lock`)
from before their first journal insert until commit, so per owner `seq` order equals
commit order and a pull never skips a change. A batch touching several owners locks
them in sorted order (no deadlocks). Owners are resolved *only through profiles the
caller can access* (`app/services/scopes.py`): an id that does not resolve is never
locked and is rejected as if it did not exist. After the locks are held the owners are
read again; if one changed (a transfer of a managed profile) the locks are released and
the step repeats, at most 3 times, then `503 retry_later`. `record_change` raises unless
the lock of the scope's owner is held by the transaction.

**Roles and writes.** A caller is `owner`, `guardian` (managed profiles), `editor` or
`viewer`. Push loads the target *without* an access filter, looks up the role, and decides
(`app/domain/write_access.py`) *before* last-write-wins, so access and privacy always win
over LWW and an upsert carrying the id of an entity the caller cannot see never reaches
the create branch. For editors, first match wins: (1) the entity or its medication is
`hidden`/`anonymous` or in no accessible scope: an upsert of an existing id is `rejected/not_found`, a delete of it is a no-op `applied`, a new schedule or dose event under it is `parent_not_found`; (2) profile upsert
or delete: `read_only`; (3) a dose event of any type: `forbidden`; (4) delete of a
medication or schedule: `forbidden`; (5) a medication upsert that changes `privacy`, or a
new medication that is not `shared`: `forbidden_field`; (6) otherwise LWW. Viewers: rule 1,
then `forbidden` for every write. Owner and guardian may do everything, except that a
guardian cannot delete a profile (`forbidden`, whatever its kind). An id (or parent) the caller has no
role on behaves like a missing one: creates under it are `parent_not_found`, deleting it is
a no-op `applied`, an upsert of an existing foreign id is `not_found`. `forbidden`,
`forbidden_field` and `read_only` carry `current`, the **projected** server state, and the
`current` of every `ignored_stale` / `key_conflict` result is projected too.

**Privacy projection** (what editors and viewers receive; owners and guardians get entities
unchanged): `shared` medications in full (dose events without `note` and `device_id`);
`anonymous` medications as `{id, profile_id, privacy, tz_mode, fixed_tz, redacted: true}`
with schedules `{id, medication_id, redacted: true, rule}` (rule without doses; kind, course
dates and times stay so the client can expand occurrences); `hidden` never. The profile is
`{id, kind, display_name, timezone}`; `updated_by_device` is `null`. OpenAPI carries
`MedicationRedacted` and `ScheduleRedacted`. A privacy change journals a `privacy` row for
the medication, journals its live schedules again, and journals its dose events again only
when they become visible (`hidden` to `shared`/`anonymous`; `shared` and `anonymous` look the
same for events). A narrowing to `hidden` reaches a client that may hold the medication as a
medication `delete` (children are skipped), only if the narrowing is newer than
`max(granted_seq, backfill_until)` and the medication appeared at or before the client's
cursor (see the pull below). Redacted (`anonymous`) changes carry `client_updated_at: null`
and, on a tombstone, `deleted_at: null`: `op` alone tells the client to delete.

**`POST /v1/sync/pull`** `{"cursors": {"<profile_id>": seq}, "limit": n, "backfill_until":
{"<profile_id>": seq}}` (1–50 cursors, `limit` ≤ 500, `backfill_until` optional, requires `X-Device-ID`, which it records at most once per
`DEVICE_TOUCH_INTERVAL_SECONDS`) answers, from one `REPEATABLE READ` snapshot per page:

```jsonc
{"scopes":  [{"profile_id", "role": "owner|guardian|editor|viewer", "kind": "self|managed",
              "archived": false, "archive_purge_after": null,
              "owner_last_seen_at": "…T08:00:00Z" /* foreign self scopes only, floored to the hour */,
              "cursor": 456 /* null when the scope was not requested */,
              "backfill_until": 789 /* projected roles, while a backfill is unfinished; else null */}],
 "revoked": ["<profile_id>"],   // requested scopes the caller cannot access
 "changes": [{"seq", "scope", "entity", "id", "op", "data", "client_updated_at",
              "updated_by_device", "deleted_at"}],
 "has_more": false}
```

`scopes` lists **every** accessible scope; `changes` come only for scopes present in
`cursors`. A client adds new scopes at cursor 0 on its next request, and with more than 50
scopes pulls them in groups of 50, each group to completion (nothing restarts from 0 by
omission). A device that knows no scope yet (first sign-in) sends one cursor for the nil UUID
`00000000-0000-0000-0000-000000000000`: it is a reserved probe id (never a profile id), answers
`revoked` and makes `scopes` list everything accessible. `revoked` holds requested scopes the caller cannot access: never-existed, foreign,
revoked and deleted look the same. An owned, deleted profile is listed only while the sent
cursor is below its tombstone's `seq`, then it moves to `revoked`. **A scope's cursor is the
newest `seq` of that scope's journal rows read in the page (not returned)**. For `editor` and
`viewer` the journal rows of `hidden` medications and their schedules and dose events are
filtered out of the read itself (only a medication's `privacy` rows are read, for the
narrowing delete), so hidden activity never moves the cursor and pages count readable rows
only. **Backfill:** a pull of a projected scope from cursor 0 returns `backfill_until` (the
newest readable `seq` in that snapshot); echo it in `backfill_until` of every following
request until the scope's cursor reaches it (the response then has `null`). Narrowing
deletes and tombstones at or below `max(granted_seq, backfill_until)` are never sent (a grant
stores `granted_seq`, the scope's journal head at accept time, under the owner's journal lock),
so a backfill never carries history from before the grant. Rows of one
entity collapse per scope into one change (its `seq` is the newest row); the page is ordered
profile, medication, schedule, dose event so parents precede children.

A change's `data` is the entity's *current* state (`null` with `op: "delete"` for tombstones,
which still carry the conflict key); the key fields are `null` for dose events (immutable).
Multiple journal rows of one entity within a page collapse into one change, ordered parents
first; its `seq` is the entity's last position. Per scope, store the scope's returned `cursor`
and repeat while `has_more`.

The Phase 2 `GET /v1/sync/pull?cursor&limit` (one cursor over the caller's own scopes) was
**removed in 3.10**; the app has used the scoped pull since 3.6. A request to it now answers
405.

**Retention (Phase 1):** tombstones and the journal are kept indefinitely, so
any cursor stays valid. Journal compaction with a retention window and
`410 cursor_expired` (client then does a full resync) is planned later.

## Layout

```
app/
  main.py            app factory; ASGI entry point app.main:app
  config.py          Settings (env)
  observability.py   JSON logging, request id, access log, last-resort 500
  errors.py          error envelope
  security.py        Argon2id, JWT, refresh tokens, code hashing
  ratelimit.py       Redis fixed-window limiter
  deps.py            FastAPI dependencies (session, current user, device id)
  db/                SQLAlchemy models and engine
  schemas/           pydantic request/response models
  services/          push_tokens, push_outbox, push_delivery, auth, account_deletion, archives, restore_tickets, erasure, entities (access-scoped CRUD),
                     dose_events, sync (push), sync_targets, sync_pull (+ sync_rows, sync_build,
                     sync_scopes), sync_state, changes (journal + locks), scopes (lock
                     resolution), scope_limit, access, invites, grants, devices,
                     missed_doses (+ missed_batch, missed_queries, missed_recipients,
                     missed_resolution: the detector), personal_data (inventory); limits.py holds protocol limits
  jobs/              erase_expired_accounts, cleanup_retention (plain async functions)
  push/              PushSender protocol, FCM, APNs, RuStore, fake and disabled senders, build_senders
  worker.py          ARQ WorkerSettings: jobs, crons, JSON serializer, job wrapper
  api/               routers (resources, sync, relatives, links, push, auth, health)
  domain/            dose_state, missed (detector rules), privacy, write_access
  domain/schedule/   schedule engine (pure; shared spec with the Dart client)
  domain/privacy.py  privacy projection for relatives (pure)
  domain/write_access.py  who may write what through sync (pure)
alembic/             migrations (async env)
tests/               API/integration tests on real Postgres + Redis
```
