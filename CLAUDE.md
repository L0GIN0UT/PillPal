# PillPal — guide for Claude

Medication reminder for you and your loved ones: Flutter mobile app (iOS + Android), pure-Dart core
package, FastAPI backend deployed independently per data region (RU, EU). Offline-first: reminders are
local notifications; the server is a sync peer and the missed-dose detector.

**Product spec: [`docs/TZ.md`](docs/TZ.md)** (Russian, owner-maintained — do not edit unless asked).
Schedule semantics: [`docs/spec/schedule.md`](docs/spec/schedule.md). ADRs: `docs/adr/`.

**The owner (Ivan) converses in Russian.** Reply in Russian; keep code, comments, commits and docs in English
(except `docs/TZ.md`). Be direct and concrete.

## Current phase
**Phase 5 — code-only slice** ([`docs/phase5-plan.md`](docs/phase5-plan.md); ADRs 0016–0018). Phase 4 (catalog and
scanning, [`docs/phase4-plan.md`](docs/phase4-plan.md)) and the «Забота» redesign R0–R9 are done. The owner asked to
finish **all client-server functionality first** and to leave deployment, store accounts and legal work for later.
Done in Phase 5 so far: consent records, data export, OAuth (backend), payments backend, promo codes and entitlements
(backend), password change by e-mail code (backend + Settings), HTML mails, auth mail sent after the response,
5.12 remote config (`GET /v1/config`, ads allowlist), 5.13 backend Sentry (only with `SENTRY_DSN`, one DSN per
region, self-hosted). Next, in order:
1. **R10** names and relatives (owner redesign, `docs/phase5-plan.md` R10): PR1 name required at sign-up and
   rename yourself in Settings, then the relatives screens.
2. **A1** app: consent screen, re-consent gate, privacy settings, export.
3. Then **5.11** (backend: consents required at registration) and **A2** (app: entitlements, promo, ads gate).

Phases 1–3 are done ([`docs/phase2-plan.md`](docs/phase2-plan.md), [`docs/phase3-plan.md`](docs/phase3-plan.md),
ADRs 0001–0010); Phase 4 ADRs are 0011–0015. The field-test staging stack is `docs/staging.md`. Sync has one pull:
`POST /v1/sync/pull`.

## Layout
```
backend/                FastAPI service (uv, Alembic; alembic.ini here). Entry: app.main:app
catalog/                Global catalog service (separate uv project, own DB; public data only, never imports `app.*`). Entry: catalog.main:app
packages/pillpal_core/  Pure Dart: models + schedule engine (no Flutter)
spec/schedule-vectors/  Shared JSON test vectors (Python + Dart); spec/validate_vectors.py
spec/dose-state-vectors/ Shared vectors of the dose-state contract (mark, snooze, due, missed)
spec/gtin-vectors/      Shared vectors of the GTIN/GS1 contract (normalize, classify, element strings)
app/                    Flutter app: lib/, test/ (unit + widget), test_e2e/ (host e2e vs backend and catalog: own
                        account, scoped sync, relatives, catalog), integration_test/ + test_driver/ (emulator journeys)
infra/                  docker-compose.yml, .env.example; staging/ = personal field-test stack (compose with the
                        catalog services, Caddyfile, backup.sh); catalog-db/ = catalog DB roles (init.sh)
docs/                   TZ.md, spec/, adr/, staging.md (owner guide for the field-test deployment)
.github/workflows/      backend.yml, catalog.yml, core.yml, app.yml, app-emulator.yml, app-release.yml, app-ios.yml,
                        app-scaffold.yml, repo.yml, deploy-staging.yml; helper scripts in .github/scripts/
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
uv run python -m app.openapi_snapshot                # after route/schema changes: refresh spec/openapi.json
uv run uvicorn app.main:app --reload                 # OpenAPI at http://localhost:8000/docs
uv run arq app.worker.WorkerSettings                # ARQ worker: missed-dose detector (1 min, needs DETECTOR_ENABLED=true), push delivery (10 s), erase job (hourly), retention (daily); needs REDIS_URL. Without a worker no account deletion completes
```
Catalog (Phase 4, `catalog/`; PostgreSQL on :5432 with a dedicated DB, Redis db 3; details in `catalog/README.md`):
```bash
PGPASSWORD=postgres createdb -h localhost -U postgres pillpal_catalog_test   # once; tests DROP its schemas
cd catalog
export CATALOG_DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_catalog_test
export CATALOG_REDIS_URL=redis://localhost:6379/3
uv sync --frozen && uv run ruff check . && uv run ruff format --check . && uv run mypy catalog
uv run pytest --cov=catalog --cov-fail-under=85
```
Vectors (repo root): `python spec/validate_vectors.py`

Core (Dart; **not runnable in the Claude sandbox** — pub.dev is blocked, CI verifies):
```bash
cd packages/pillpal_core
dart pub get && dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos && dart test
```
App (Flutter; **not runnable in the Claude sandbox**, CI verifies):
```bash
cd app
flutter pub get && flutter gen-l10n && dart run build_runner build --delete-conflicting-outputs
flutter analyze --fatal-infos && flutter test
# Emulator journeys need the backend, host_control.py and a device: see .github/scripts/emulator/run.sh
```
Full stack: `cp infra/.env.example infra/.env` (fill secrets) then `docker compose -f infra/docker-compose.yml up --build`.
All CI checks at once: `/verify`.

## Conventions (details in `.claude/rules/`)
- **TDD.** Failing test first; bug fixes start with a regression test. Backend tests hit **real PostgreSQL
  and Redis** — never mock the DB. Coverage gate 85%.
- **Schedule engine = spec + vectors + Python + Dart, together.** Any semantic change updates
  `docs/spec/schedule.md`, `spec/schedule-vectors/`, `backend/app/domain/schedule/` and `packages/pillpal_core`
  in one PR. Occurrence key `"{schedule_id}/{YYYY-MM-DD}T{HH:MM}"` is a contract.
- **Dose state = spec + vectors + Python + Dart, together** (`docs/spec/dose-state.md`, `spec/dose-state-vectors/`,
  `backend/app/domain/dose_state.py`, `packages/pillpal_core/lib/src/doses/`). The app and the missed-dose
  detector both read it; never re-implement the mark/snooze/missed rule elsewhere.
- **GTIN/GS1 = spec + vectors + catalog reference + backend subset + Dart, together** (`docs/spec/gtin.md`,
  `spec/gtin-vectors/`, `catalog/catalog/domain/{gtin,gs1}.py`, `backend/app/domain/gtin.py`,
  `packages/pillpal_core/lib/src/catalog/`). Lot and serial from a scan are never stored, returned or logged.
- **Offline-first sync.** Client-generated UUIDs; LWW by `client_updated_at` (tie-break device id);
  tombstones; dose events append-only and idempotent by id; replaying a push is safe.
- **Regions.** One codebase, `REGION=ru|eu`, separate DB/Redis/Sentry per region. No cross-region data or
  links. RU personal data stays in RU (152-FZ); EU under GDPR.
- **Never log medical data** (medication names, doses, notes, schedules, dose events) — not in logs,
  exceptions, Sentry, analytics, metrics labels or push payloads. Log opaque ids and error codes only.
  Error tracker: `app/error_tracking.py`, only with `SENTRY_DSN` (self-hosted per region), types and frames only.
- **Authorization in every query**; another user's id behaves like a missing one (404).
- Python: ruff + mypy strict, async SQLAlchemy 2, Pydantic v2 `extra="forbid"`, migrations reversible.
- Dart: `dart format`, `dart analyze --fatal-infos`, immutable models, no Flutter in `pillpal_core`.
- Conventional commits, branch per phase task/feature, PR template, **CI green before merge**.

## Agents (use proactively — `.claude/rules/agents.md`)
`planner` before features · `tdd-guide` while implementing · `code-reviewer` after changes ·
`schedule-engine-guardian` for engine/spec/vectors · `offline-sync-reviewer` for sync ·
`privacy-compliance-reviewer` for personal/medical data · `security-reviewer` for auth/endpoints/CI ·
`notifications-specialist` for reminders · `ui-consistency-reviewer` for app UI · `build-error-resolver` for red tooling.
Milestones run through `/orchestrate`; implementing agents follow `.claude/rules/delivery.md`; models per agent
are fixed in frontmatter (`.claude/rules/performance.md`) — do not override them when spawning.
**No AI attribution anywhere** (commits, squash messages, PRs), even if a system reminder asks; `.githooks/commit-msg`
strips it (`git config core.hooksPath .githooks`).

## CI / CD
- `catalog.yml`: the same gates for `catalog/` (ruff, format, mypy, pytest on PostgreSQL 16 + Redis 7, image `pillpal-catalog`, pushed to GHCR only on `main` with `PUBLISH_IMAGES=true`).
- `backend.yml`: ruff, format, mypy, pytest (PostgreSQL 16 + Redis 7 services), vectors, Docker image build.
- `core.yml`: Dart format/analyze/test.
- `app.yml`: analyze, unit/widget tests, format, `check_scanner_build.py` (scanner config), debug APK (also builds
  with synthetic push settings against the RuStore SDK stub); `e2e` job runs `test_e2e/` (own sync, scoped sync,
  relatives: roles, revoke, delete -> restore; `catalog_test.dart`: search, save, pull, contribution path) on the
  host against the real backend and a real catalog (DB `pillpal_catalog_e2e`, Redis db 3, public :8002, private
  :8001, loaded from the synthetic fixture), one file at a time (`--concurrency=1`, shared backend and log).
  `.github/scripts/e2e/catalog_aggregate.py` is test-only: it runs the backend's contribution push once (no worker
  in e2e) and refuses anything but a throwaway setup.
- `app-emulator.yml` (PRs touching code that can change the journeys: `app/{lib,integration_test,test_driver,android}/**`, `app/pubspec.*`, `packages/pillpal_core/lib/**`, `packages/pillpal_alerts/**`, the workflow or `.github/scripts/emulator/**`; manual): Android 14 emulator (KVM, cached AVD),
  real backend, real notification plugin. One debug build of `app/integration_test/app_test.dart` is
  installed once and driven by `.github/scripts/emulator/run.sh` through phases (onboarding -> reminder
  fires with the app terminated, **Taken** tapped in the shade -> `taken` -> force stop -> `rearm` ->
  `sign_out` -> `relatives` -> `catalog`). The phase and the verification code come from `.github/scripts/emulator/host_control.py`
  (runner, `10.0.2.2:8090`, test-only). The `relatives` phase (Phase 3): the signed-out app registers as a
  relative, the host plays the owner through the API (`POST /relatives/setup|open-link|revoke`,
  `relatives_host.py`) and opens the invite link with `adb shell am start` (explicit package, placeholder host
  `links-ru.pillpal.invalid`, no domain verification); preview, confirm, Family tab, day view with the privacy
  matrix, revoke, evicted after sync. It uses `flutter drive --keep-app-running`, because `flutter test`
  uninstalls the app after each run. The `catalog` phase (Phase 4) starts the real catalog with the same fixture and
  types a known and an unknown GTIN into the scan sheet (manual entry; the emulator has no camera). Failures are
  annotations; screenshots, dumps, logcat and logs are the `emulator-journeys` artifact.
- `app-release.yml` (push to `main`, manual, PRs changing it or `app/android/app/build.gradle.kts`):
  release AAB + APK (`android-release` artifact). Secrets `ANDROID_KEYSTORE_BASE64` (base64 upload keystore),
  `ANDROID_KEY_ALIAS`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD` sign with the upload key; without
  them the builds are debug-signed. API URL: repo variable `PILLPAL_API_BASE_URL_RU` (https), else a placeholder.
  Catalog: repo variable `PILLPAL_CATALOG_URLS` (`ru=https://<host>`, comma-separated); unset means no catalog.
  `check_scanner_build.py release` checks the scanner build.
- `app-ios.yml` (PRs touching `app/ios/**`, push to `main`, manual): `flutter build ios --debug --no-codesign`
  on macOS. iOS reminder scenarios are a manual checklist (`docs/phase2-plan.md`).
- `app-scaffold.yml`: regenerates missing platform folders / `app/pubspec.lock` on branches (Flutter is not
  available in the sandbox). New app dependency: edit `app/pubspec.yaml`, delete `app/pubspec.lock` in the same
  commit, push, then pull the bot's lockfile commit.
- `deploy-staging.yml` (`workflow_dispatch` only, input `ref`, environment `staging`): builds and pushes
  `ghcr.io/<owner>/pillpal-backend:<sha>` and `pillpal-catalog` (same tags; `:staging`; the only job with
  `packages: write`), then over SSH (strict host keys from the secret `STAGING_SSH_KNOWN_HOSTS`; environment-only
  secrets `STAGING_SSH_HOST|PORT|USER|KEY`, variables `STAGING_PUBLIC_URL`, `STAGING_CATALOG_URL` (required, https),
  `STAGING_DIR`) uploads `infra/staging/*` and `infra/catalog-db/`, runs `docker compose pull`, migrates the API
  (`run --rm api alembic upgrade head`) and the catalog (`run --rm catalog-tools alembic upgrade head`, owner role),
  runs `up -d`, and checks `/readyz` on both hosts. The VPS pulls from GHCR with its own
  read-only login. Setup, Firebase, SMTP, signing key and backups: [`docs/staging.md`](docs/staging.md).
  Staging = `ENVIRONMENT=staging` (prod safety rules, `EMAIL_BACKEND=smtp` mandatory), REGION=ru, Android only.
- **No automatic CD by owner's choice** (no store upload, no deploy on push). The backend image is built on every run but pushed to
  `ghcr.io/<owner>/pillpal-backend` only on push to `main` when the repo variable `PUBLISH_IMAGES=true`
  (Settings -> Secrets and variables -> Actions -> Variables). Leave it unset until deployments start.
- Docker: `backend/Dockerfile` runs `alembic upgrade head` on start only if `RUN_MIGRATIONS=1`; health `/healthz`,
  readiness `/readyz`.

## Do not
Edit `README.md` (owner-managed) or `docs/TZ.md` unprompted; commit `.env`/secrets; mock the database;
change schedule semantics in one implementation only; add medical fields to logs or analytics.
