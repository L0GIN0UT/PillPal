# PillPal catalog service

Global medicine catalog: public reference data only. It has **no users, accounts, devices or tokens of
end users**, and it must never import the regional backend (`app.*`). Both rules are enforced by tests
(`tests/test_privacy_boundary.py`). Milestone 4.1 is the skeleton: health probes, logging, error envelope,
rate limiting and the database baseline. Catalog tables and endpoints follow in 4.3+.

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
| `CATALOG_RATE_LIMIT_SALT` | random per process | HMAC key of rate-limit buckets; set it when running several processes |
| `CATALOG_RATE_LIMIT_WINDOW_SECONDS`, `CATALOG_RATE_LIMIT_IP_MAX`, `CATALOG_RATE_LIMIT_INSTALL_MAX` | 60 / 240 / 60 | fixed window per IP and per `X-Catalog-Install` |
| `LOG_LEVEL` | `INFO` | |
| `CATALOG_DB_POOL_SIZE` | 5 | |
| `RUN_MIGRATIONS` | `0` | Docker entrypoint applies migrations when `1` |

## Privacy rules

- Access log: method, route template, status, duration and a random request id. Never the query string,
  body, client IP, user agent or `X-Catalog-Install`.
- Rate-limit Redis keys are HMAC hashes with a one-window TTL; nothing is stored in PostgreSQL.
- Keep PostgreSQL statement logging (`log_statement`, `log_min_duration_statement`) off for this database.
- No CORS, no cookies, no authentication on public routes.
