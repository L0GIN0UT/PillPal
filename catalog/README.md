# PillPal catalog service

Global medicine catalog: public reference data only. It has **no users, accounts, devices or tokens of
end users**, and it must never import the regional backend (`app.*`). Both rules are enforced by tests
(`tests/test_privacy_boundary.py`). Milestone 4.1 is the skeleton (health probes, logging, error envelope, rate limiting, database
baseline); 4.3 adds the data model and the importer framework. Endpoints and real importers follow in 4.4+.

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
| `CATALOG_ADMIN_TOKENS`, `CATALOG_INGEST_TOKENS` | empty | comma-separated `name:sha256hex` (SHA-256 of a random secret of >= 32 characters, e.g. `python -c "import secrets,hashlib; s=secrets.token_urlsafe(48); print(s, hashlib.sha256(s.encode()).hexdigest())"`); both required in staging and prod; no endpoint uses them yet |
| `CATALOG_RATE_LIMIT_SALT` | random per process in dev/test | HMAC key of rate-limit buckets; **required in staging and prod**, because a per-process random salt would split the buckets of several processes and reset on every restart |
| `CATALOG_RATE_LIMIT_UNAVAILABLE_SECONDS` | 30 | after a Redis failure the limiter skips Redis (fail-open) for this long and logs one warning |
| `FORWARDED_ALLOW_IPS` | empty (image) | addresses whose `X-Forwarded-For` uvicorn believes: the reverse proxy's address or subnet, **never `*`** (any client could then pick the IP the rate limiter sees). Empty trusts nobody, not even loopback; then every client looks like the proxy and the IP bucket becomes global |
| `CATALOG_RATE_LIMIT_WINDOW_SECONDS`, `CATALOG_RATE_LIMIT_IP_MAX`, `CATALOG_RATE_LIMIT_INSTALL_MAX` | 60 / 240 / 60 | fixed window per IP and per `X-Catalog-Install` |
| `CATALOG_IMPORTER_ESKLP_ENABLED` | `false` | ESKLP has no published license text: the importer refuses to run until the owner sets this to `true` (D1) |
| `CATALOG_IMPORTER_GRLS_ENABLED` | `false` | same gate for the GRLS manual-export importer (4.4b) |
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

- Exit codes: 0 ok, 1 failed (code on stderr), 2 usage, 3 refused (disabled source, run in progress, fixture in
  staging/prod).
- Rows are never deleted: a row missing from a snapshot gets `withdrawn_at` and stays resolvable by id.
  `--no-withdraw` is for partial manual exports (GRLS).
- `fixture` is synthetic and development-only (it registers its own `sources` row); the CLI refuses it when
  `ENVIRONMENT` is `staging` or `prod`. `esklp` is a stub that refuses unless its flag is set.
- A run never stays `running`: cancellation and interrupts mark it `failed` (`import_aborted`); after a hard kill
  the next run takes over a row older than `CATALOG_IMPORTER_STALE_RUN_MINUTES`.
- `ENVIRONMENT` defaults to `dev`, so the `fixture` source is allowed when it is unset; set it to `staging` or
  `prod` on real deployments (those two also require the service tokens).

## Database role

`infra/catalog-db/init.sh` (compose service `catalog-db`) creates the database `pillpal_catalog` and a
dedicated role `catalog`: not a superuser, owner of that database only, `CONNECT` on the backend's database
revoked from `PUBLIC`. `pg_trgm` and `unaccent` are trusted extensions, so the migration runs as that role
(tested in `tests/test_provisioning.py`). The `catalog` service gets only `CATALOG_*`, `ENVIRONMENT`,
`LOG_LEVEL` and `FORWARDED_ALLOW_IPS`, never the backend's `.env`. The script also sets
`log_statement=none`, `log_min_duration_statement=-1` and `log_parameter_max_length_on_error=0` on the catalog
database; outside compose, apply the same to your database.

## Privacy rules

- Access log: method, route template, status, duration and a random request id. Never the query string,
  body, client IP, user agent or `X-Catalog-Install`.
- Rate-limit Redis keys are HMAC hashes with a one-window TTL; nothing is stored in PostgreSQL.
- PostgreSQL statement logging is off for this database (see above).
- No CORS, no cookies, no authentication on public routes.
