# PillPal backend

FastAPI service for PillPal. One codebase, deployed once per data region
(`REGION=ru` or `REGION=eu`). Each stand serves only accounts of its own region.
Spec: `docs/TZ.md` §3, §4.1–4.3. Schedule rules: `docs/spec/schedule.md`.

Stack: Python ≥ 3.12, FastAPI, SQLAlchemy 2 (async) + asyncpg, Alembic,
PostgreSQL 16, Redis, pydantic v2, Argon2id, PyJWT, structlog. Dependencies are
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

## Configuration

| Variable | Required | Default | Notes |
|---|---|---|---|
| `REGION` | yes | — | `ru` or `eu` |
| `ENVIRONMENT` | no | `dev` | `dev`, `test` or `prod`. `prod` forbids `LOG_EMAIL_CODES=true` and refuses to start without a real e-mail provider (none exists yet in Phase 1: the logging-only sender would drop every code) |
| `DATABASE_URL` | yes | — | `postgresql://` is rewritten to `postgresql+asyncpg://` |
| `JWT_SECRET` | yes | — | ≥ 32 chars; also keys the e-mail code HMAC |
| `REDIS_URL` | no | `redis://localhost:6379/0` | auth rate limiting |
| `ACCESS_TOKEN_TTL_SECONDS` | no | `900` | access JWT lifetime (15 min) |
| `REFRESH_TOKEN_TTL_SECONDS` | no | `2592000` | 30 days |
| `EMAIL_CODE_TTL_SECONDS` | no | `900` | 6-digit codes |
| `EMAIL_CODE_MAX_ATTEMPTS` | no | `5` | wrong attempts per code |
| `EMAIL_CODE_WINDOW_SECONDS` | no | `86400` | window for the two limits below |
| `EMAIL_CODE_DAILY_CAP` | no | `5` | codes issued per account and purpose per window (further requests answer the same but send nothing) |
| `EMAIL_CODE_MAX_FAILED_PER_WINDOW` | no | `10` | wrong guesses per account and purpose per window, summed over all codes (a new code does not reset it) |
| `LOG_EMAIL_CODES` | no | `false` | dev only; rejected when `ENVIRONMENT=prod` |
| `RATE_LIMIT_AUTH_MAX_ATTEMPTS` | no | `10` | per (IP, e-mail) and per e-mail across all IPs, per window |
| `RATE_LIMIT_AUTH_WINDOW_SECONDS` | no | `900` | fixed window |
| `RATE_LIMIT_IP_MULTIPLIER` | no | `10` | per-IP bucket = max × multiplier |
| `PASSWORD_HASH_TIME_COST` / `_MEMORY_KIB` / `_PARALLELISM` | no | `3` / `65536` / `4` | Argon2id |
| `DB_POOL_SIZE` | no | `10` | |
| `LOG_LEVEL` | no | `INFO` | |
| `CORS_ORIGINS` | no | `[]` | JSON list; CORS is off when empty (mobile clients need none) |

## Tests and checks

Tests use a **real** PostgreSQL and Redis (no SQLite, no DB mocks). The suite
drops and recreates the `public` schema of the test database and runs the
Alembic migrations once per session; each test truncates tables and flushes
the Redis DB. One test also creates/drops a scratch database
`pillpal_test_migrations` to check upgrade → downgrade → upgrade.

```bash
export DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_test
export REDIS_URL=redis://localhost:6379/0   # this DB is FLUSHED by the tests
export REGION=ru JWT_SECRET=test-secret-test-secret-test-secret

uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest --cov=app --cov-fail-under=85
```

`TEST_DATABASE_URL` / `TEST_REDIS_URL` override the URLs above for tests only.

## API overview (`/v1`)

All errors use one envelope: `{"error": {"code": "...", "message": "..."}}`
(422 adds `details: [{loc, msg}]`; input values are never echoed). Every
response carries `X-Request-ID` (client-supplied value is echoed if valid).

| Area | Endpoints |
|---|---|
| Auth | `POST /auth/register` (always 202 `{"status":"verification_sent"}`; `region` must match the server, else 409 `wrong_region`), `POST /auth/verify-email` `{email, code}` → token pair, `POST /auth/verify-email/resend` `{email}` (always 202), `POST /auth/login` (403 `email_not_verified` after a correct password), `POST /auth/refresh`, `POST /auth/logout`, `POST /auth/password-reset/request`, `POST /auth/password-reset/confirm` |
| Me | `GET /me`, `DELETE /me` with body `{password}` (401 `invalid_password`; erases the account and all its data) |
| Profiles | `GET/POST /profiles`, `GET/PATCH/DELETE /profiles/{id}` |
| Medications | `GET/POST /profiles/{id}/medications`, `GET/PATCH/DELETE /medications/{id}` |
| Schedules | `GET/POST /medications/{id}/schedules`, `GET/PATCH/DELETE /schedules/{id}` |
| Dose events | `POST /dose-events` (201 new, 200 identical replay, 409 different payload), `GET /dose-events?profile_id&medication_id&from&to&limit`, `GET /dose-events/{id}` |
| Sync | `POST /sync/push` (header `X-Device-ID` required), `GET /sync/pull?cursor&limit` (limit ≤ 500) |

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
- **Account deletion erases**: `DELETE /me` removes the user and every row it
  owns (profiles, medications, schedules, dose events, journal, devices,
  tokens, codes) in one transaction; the address can register again.
- **Dose events are append-only** (DB trigger rejects UPDATE/DELETE). Corrections
  are `undo` events with `target_event_id`. The only exception is account
  erasure: the trigger lets DELETE (never UPDATE) through while
  `pillpal.purge = 'on'`, which only the erasure transaction sets (`SET LOCAL`).
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

### Sync protocol

`POST /v1/sync/push` body: `{"mutations": [{entity, op, id, data, client_updated_at}]}`,
`entity ∈ profile|medication|schedule|dose_event`, `op ∈ upsert|delete`, at most
500 per batch. `data` is the entity's **full** state for upserts:

- profile: `{kind?: "managed"|"self", display_name, timezone}` (new profiles must be `managed`)
- medication: `{profile_id, name, form?, strength_text?, notes?, tz_mode, fixed_tz?, stock_count?, stock_unit?, low_stock_days?, privacy}`
- schedule: `{medication_id, rule}`
- dose_event: `{medication_id, type, at, occurrence_key?, target_event_id?, note?}`

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

Every applied change appends to `sync_changes` (`seq BIGSERIAL`). All
journaling transactions of one user hold a per-user advisory lock
(`pg_advisory_xact_lock`) from before their first journal insert until commit,
so `seq` order equals commit order and a pull never skips a change.
`GET /v1/sync/pull?cursor=<seq>&limit=<n>` (`0 ≤ cursor ≤ 2^63-1`) returns
`{changes: [{seq, entity, id, op, data, client_updated_at, updated_by_device,
deleted_at}], next_cursor, has_more}`. `data` is the entity's *current* state
(`null` with `op: "delete"` for tombstones, which still carry the conflict
key); the key fields are `null` for dose events (immutable). Multiple journal
rows of one entity within a page collapse into one change, placed at the
entity's *first* position in the page (parents before children); its `seq` is
the entity's last position. Store `next_cursor` and repeat while `has_more`.

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
  services/          auth, erasure (account deletion), entities (owner-scoped CRUD),
                     dose_events, sync (push), sync_pull, changes (journal + lock)
  api/               routers
  domain/schedule/   schedule engine (pure; shared spec with the Dart client)
alembic/             migrations (async env)
tests/               API/integration tests on real Postgres + Redis
```
