# PillPal — guide for Claude

Medication reminder for you and your loved ones: Flutter mobile app (iOS + Android), pure-Dart core
package, FastAPI backend deployed independently per data region (RU, EU). Offline-first: reminders are
local notifications; the server is a sync peer and the missed-dose detector.

**Product spec: [`docs/TZ.md`](docs/TZ.md)** (Russian, owner-maintained — do not edit unless asked).
Schedule semantics: [`docs/spec/schedule.md`](docs/spec/schedule.md). ADRs: `docs/adr/`.

**The owner (Ivan) converses in Russian.** Reply in Russian; keep code, comments, commits and docs in English
(except `docs/TZ.md`). Be direct and concrete.

## Current phase
**Phase 1 — foundation and core** (TZ §5): monorepo + `.claude/`, CI, backend core (auth, profiles,
medications, schedules, dose events, push/pull sync), schedule engine (spec, vectors, Python + Dart),
design system and key screen mockups. Do not start Phase 2+ work (Flutter app, relatives, catalog,
payments) unless asked.

## Layout
```
backend/                FastAPI service (uv, Alembic; alembic.ini here). Entry: app.main:app
packages/pillpal_core/  Pure Dart: models + schedule engine (no Flutter)
spec/schedule-vectors/  Shared JSON test vectors (Python + Dart); spec/validate_vectors.py
app/                    Flutter app (Phase 2, not yet created)
infra/                  docker-compose.yml, .env.example
docs/                   TZ.md, spec/, adr/
.github/workflows/      backend.yml, core.yml, app.yml (Phase 2 placeholder)
.claude/                agents, rules, commands, skills (see .claude/README.md)
```

## Commands
Backend (needs PostgreSQL 16 on :5432 and Redis on :6379):
```bash
docker compose -f infra/docker-compose.yml up -d postgres redis   # or: service postgresql start; redis-server --daemonize yes
docker compose -f infra/docker-compose.yml exec postgres createdb -U postgres pillpal_test   # once; tests DROP its schema
cd backend
export DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_test
export REDIS_URL=redis://localhost:6379/0 REGION=ru JWT_SECRET=ci-secret-not-for-prod-ci-secret-not-for-prod
uv sync --frozen
uv run ruff check . && uv run ruff format --check .
uv run mypy app
uv run pytest --cov=app --cov-fail-under=85         # tests FLUSH the Redis DB and reset the test schema
uv run alembic upgrade head                          # against $DATABASE_URL
uv run uvicorn app.main:app --reload                 # OpenAPI at http://localhost:8000/docs
```
Vectors (repo root): `python spec/validate_vectors.py`

Core (Dart; **not runnable in the Claude sandbox** — pub.dev is blocked, CI verifies):
```bash
cd packages/pillpal_core
dart pub get && dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos && dart test
```
Full stack: `cp infra/.env.example infra/.env` (fill secrets) then `docker compose -f infra/docker-compose.yml up --build`.
All CI checks at once: `/verify`.

## Conventions (details in `.claude/rules/`)
- **TDD.** Failing test first; bug fixes start with a regression test. Backend tests hit **real PostgreSQL
  and Redis** — never mock the DB. Coverage gate 85%.
- **Schedule engine = spec + vectors + Python + Dart, together.** Any semantic change updates
  `docs/spec/schedule.md`, `spec/schedule-vectors/`, `backend/app/domain/schedule/` and `packages/pillpal_core`
  in one PR. Occurrence key `"{schedule_id}/{YYYY-MM-DD}T{HH:MM}"` is a contract.
- **Offline-first sync.** Client-generated UUIDs; LWW by `client_updated_at` (tie-break device id);
  tombstones; dose events append-only and idempotent by id; replaying a push is safe.
- **Regions.** One codebase, `REGION=ru|eu`, separate DB/Redis/Sentry per region. No cross-region data or
  links. RU personal data stays in RU (152-FZ); EU under GDPR.
- **Never log medical data** (medication names, doses, notes, schedules, dose events) — not in logs,
  exceptions, Sentry, analytics, metrics labels or push payloads. Log opaque ids and error codes only.
- **Authorization in every query**; another user's id behaves like a missing one (404).
- Python: ruff + mypy strict, async SQLAlchemy 2, Pydantic v2 `extra="forbid"`, migrations reversible.
- Dart: `dart format`, `dart analyze --fatal-infos`, immutable models, no Flutter in `pillpal_core`.
- Conventional commits, branch per phase task/feature, PR template, **CI green before merge**.

## Agents (use proactively — `.claude/rules/agents.md`)
`planner` before features · `tdd-guide` while implementing · `code-reviewer` after changes ·
`schedule-engine-guardian` for engine/spec/vectors · `offline-sync-reviewer` for sync ·
`privacy-compliance-reviewer` for personal/medical data · `security-reviewer` for auth/endpoints/CI ·
`notifications-specialist` for reminders (Phase 2) · `build-error-resolver` for red tooling.

## CI / CD
- `backend.yml`: ruff, format, mypy, pytest (PostgreSQL 16 + Redis 7 services), vectors, Docker image build.
- `core.yml`: Dart format/analyze/test. `app.yml`: Flutter, no-op until `app/pubspec.yaml` exists.
- **No CD in Phase 1 by owner's choice.** The backend image is built on every run but pushed to
  `ghcr.io/<owner>/pillpal-backend` only on push to `main` when the repo variable `PUBLISH_IMAGES=true`
  (Settings -> Secrets and variables -> Actions -> Variables). Leave it unset until deployments start.
- Docker: `backend/Dockerfile` runs `alembic upgrade head` on start only if `RUN_MIGRATIONS=1`; health `/healthz`,
  readiness `/readyz`.

## Do not
Edit `README.md` (owner-managed) or `docs/TZ.md` unprompted; commit `.env`/secrets; mock the database;
change schedule semantics in one implementation only; add medical fields to logs or analytics.
