# ADR 0011 — Catalog service boundary and deployment (Phase 4)

- Status: accepted
- Date: 2026-10-21
- Scope: TZ §1 (regions), §2.1 ("Каталог GTIN/справочник — глобальный сервис без персональных
  данных"), §5 "Фаза 4"; new top-level project `catalog/` (FastAPI, uv, Alembic, Docker image
  `pillpal-catalog`, workflow `catalog.yml`); backend `app/catalog_client.py`; app
  `data/catalog/`; `infra/docker-compose.yml`, `infra/staging/`
- Related: owner decision D2 (`docs/phase4-plan.md`), ADR 0012 (data model and sources),
  ADR 0014 (consensus), ADR 0015 (app integration and traffic privacy),
  `.claude/rules/privacy.md` rules 1–4, `.claude/rules/security.md`

## Context

Phase 4 adds a drug catalog: sources, import pipeline, search, GTIN lookup and the consensus
of user-contributed GTIN→product links. The TZ requires it to be a **global service without
personal data**, while all user data stays in regional deployments (RU under 152-FZ, EU
under GDPR) with no cross-region stores or links.

The regional backend (`backend/`) holds users, tokens, medical data and the JWT secret. If
the catalog lived in the same codebase and image, "the catalog has no personal data" would
be a review promise rather than a property of the deployment: one wrong import or one
shared session factory would be enough to break it. Importers also pull in archive, CSV and
xlsx parsing of untrusted downloads, which should not widen the backend's attack surface.

The app must stay usable without the catalog (offline-first), and a personal RU staging
stack with installed field-test APKs already exists (`docs/staging.md`), so the catalog has
to be added next to it, not instead of it.

## Decision

### 1. A separate uv project `catalog/` with its own image and database

- `catalog/` at the repository root: `pyproject.toml`, `uv.lock`, `alembic.ini`,
  `Dockerfile`, package `catalog/catalog/` (`main.py`, `config.py`, `observability.py`,
  `errors.py`, `ratelimit.py`, `db/`, `domain/`, `importers/`, `services/`, `api/`,
  `schemas/`, `admin/`), `tests/`, `README.md`, `LICENSES.md`.
- Its own PostgreSQL database (`pillpal_catalog`, test `pillpal_catalog_test`) with its own
  `alembic_version` and revision ids `c0001…`; Redis for rate limiting only (a separate DB
  index from the backend in dev).
- Its own CI workflow `catalog.yml` (ruff, format, mypy strict, pytest ≥ 85 % on real
  PostgreSQL and Redis, image build; GHCR push only on `main` with `PUBLISH_IMAGES=true`, as
  for the backend).
- The same conventions as the backend: Python 3.12, async SQLAlchemy 2, Pydantic v2 with
  `extra="forbid"`, `domain/` pure, structured logging, error envelope
  `{"error": {"code", "message"}}`, non-root container, `/healthz` and `/readyz`.

### 2. No personal data by construction

- The catalog package never imports `app.*`; a test in 4.1 asserts it. There is no user,
  device, session, token or e-mail model, and a schema-introspection test asserts that no
  table has a column named `email`, `user_id`, `device*` or `ip`.
- Public endpoints take **no `Authorization` header** and the server rejects one with
  `400 unexpected_authorization`, so a misconfigured client cannot leak a backend token.
- The only identifier the catalog ever sees from a device is a random, catalog-only
  install id (`X-Catalog-Install`, ADR 0015 §3), used in a salted, short-TTL rate-limit
  key and never stored.
- Contributions arrive as aggregates `{gtin, product_id, count}` from the regional backend
  (ADR 0014); no user, profile or device id crosses the boundary.
- Access logs carry route template, status, latency and request id. No query strings,
  bodies, client IPs or GTINs. PostgreSQL `log_statement`/`log_min_duration_statement`
  parameter logging is off for the catalog database (documented in `docs/staging.md`).

### 3. Deployment: one catalog per region by default (D2)

- Default topology: a catalog instance next to each regional stand, reached by the app of
  that region only (`PILLPAL_CATALOG_URLS=ru=…,eu=…`, ADR 0015 §3). Each instance imports
  the same public sources; ids are deterministic (ADR 0012 §2), so the two instances agree
  on every product id without coordination.
- Contributions from a region go to the catalog of that region, so even aggregates do not
  cross a border by default (152-FZ optics, privacy rule 3).
- The same image also supports a **single global deployment**: `gtin_link_candidates` is
  keyed by `region`, ingest tokens are region-bound, and `decide()` sums counts over
  regions. Switching is an operations decision, not a code change.
- The staging field-test stack (`infra/staging/`) gains a `catalog` service and database in
  milestone 4.12 and is otherwise unchanged; until then the app hides catalog UI when
  `PILLPAL_CATALOG_URLS` is unset.

### 4. Surfaces and trust zones

| Surface | Path prefix | Caller | Auth | Exposed by the public proxy |
|---|---|---|---|---|
| Public | `/v1/*` | the app | none; rate limit per IP and per install id | yes |
| Internal | `/internal/v1/*` | the regional backend's ARQ job | region-bound bearer token (`CATALOG_INGEST_TOKENS`) | no (private network / separate listener) |
| Admin | `/admin/v1/*` and `python -m catalog.admin` | the owner | named bearer tokens (`CATALOG_ADMIN_TOKENS`), audited | no |
| Health | `/healthz`, `/readyz` | orchestrator | none | `/readyz` only |

Tokens are compared in constant time against `sha256` values from settings; strict
environments refuse tokens shorter than 32 characters. The backend calls the catalog only
from the worker (`app/catalog_client.py`, https required in strict environments), **never on
a request path**, so a slow or down catalog cannot affect sync or auth.

### 5. Duplicated helpers, shared vectors

About 300 lines (logging setup, request id, error envelope, rate limiter, settings
scaffolding) are copied from `backend/` rather than extracted into a shared package. A
shared package would couple the two images' build contexts and dependency sets, which is
what this ADR separates. The GTIN normalization and shareable rule exist in three
implementations (catalog Python as reference, a backend subset, Dart) and are kept equal by
the shared vectors `spec/gtin-vectors/` (ADR 0013), the same discipline as the schedule and
dose-state contracts.

### 6. Threat model (summary)

- **Catalog compromise** exposes public drug data, aggregate counts per region and admin
  audit rows (token labels). No account can be identified from it.
- **Backend compromise** cannot reach the catalog's admin surface (different tokens) and
  gains nothing from the catalog beyond public data.
- **Malicious client**: unauthenticated search is rate-limited per IP and per install id,
  bodies are capped at 4 KiB, `limit` is capped, statements have a 300 ms timeout, and no
  endpoint echoes input. Contributions cannot be forged from a client: only the backend
  holds an ingest token, and a contribution needs an account that is verified, not
  pending deletion and at least 7 days old (ADR 0014).
- **Poisoned source download**: fetches verify sha256 and size caps; archives are extracted
  with path checks; parsing runs with the importer's own limits, outside the backend image.

## Consequences

- A second service to build, test, migrate and deploy: `catalog.yml`, a second database in
  `infra/docker-compose.yml` and in staging, `deploy-staging.yml` runs `alembic upgrade
  head` for both.
- `CLAUDE.md` gains the catalog layout and commands in 4.1 and 4.12.
- Backend and app get an optional dependency on the catalog: the app degrades to free text
  and "scan to remember"; the backend's only link is the hourly aggregator job behind
  `CATALOG_CONTRIBUTIONS_ENABLED`.
- Some helper code is duplicated (§5); refactors must be applied twice.
- Operating two regional catalogs means two import runs per source release. The CLI is
  reproducible from a pinned snapshot, so both produce identical rows.

## Alternatives considered

- **A second entrypoint inside `backend/`** (shared models, one image): smallest diff, but
  the privacy boundary becomes a review rule instead of a property; importer dependencies
  enter the backend image; one deploy unit for two cadences.
- **A shared `pillpal_common` Python package**: avoids the 300 duplicated lines but couples
  build contexts and lockfiles of two images; rejected for now, reconsidered if a third
  service appears.
- **One global catalog only**: fewer deployments, but user contributions would cross
  regions by default and the RU stand would depend on a service outside Russia for search;
  kept as a supported option, not the default (D2).
- **Catalog data embedded in the app** (SQLite bundle): offline search, but the bundle would
  be tens of megabytes per market, updates would need releases, and consensus would still
  need a server. Linked products are cached on the device instead (ADR 0015 §2).
