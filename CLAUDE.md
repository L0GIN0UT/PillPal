# PillPal — guide for Claude

Medication reminder for you and your loved ones: Flutter mobile app (iOS + Android), pure-Dart core
package, FastAPI backend deployed independently per data region (RU, EU). Offline-first: reminders are
local notifications; the server is a sync peer and the missed-dose detector.

**Product spec: [`docs/TZ.md`](docs/TZ.md)** (Russian, owner-maintained — do not edit unless asked).
Schedule semantics: [`docs/spec/schedule.md`](docs/spec/schedule.md). ADRs: `docs/adr/`.

**The owner (Ivan) converses in Russian.** Reply in Russian; keep code, comments, commits and docs in English
(except `docs/TZ.md`). Be direct and concrete.

## Current phase
**Phase 3 — Relatives** (TZ §2.5, §5) is **done** (milestones 3.0–3.10, PRs #11–#23): plan, status table, the
owner's manual checklist (push credentials, link domain, Xcode capabilities, `DETECTOR_ENABLED` rollout, legal
review) and known follow-ups are in [`docs/phase3-plan.md`](docs/phase3-plan.md); decisions in ADRs 0005–0010
(`docs/adr/`). Phase 1 (backend core, schedule engine, CI) and Phase 2 (Flutter app, offline core,
[`docs/phase2-plan.md`](docs/phase2-plan.md)) are done too. **Phase 4+ (catalog, payments, OAuth, regional
deployments) starts only when the owner asks.** Sync has one pull: `POST /v1/sync/pull` (scoped); the Phase 2
`GET /v1/sync/pull` was removed in 3.10.

## Layout
```
backend/                FastAPI service (uv, Alembic; alembic.ini here). Entry: app.main:app
packages/pillpal_core/  Pure Dart: models + schedule engine (no Flutter)
spec/schedule-vectors/  Shared JSON test vectors (Python + Dart); spec/validate_vectors.py
spec/dose-state-vectors/ Shared vectors of the dose-state contract (mark, snooze, due, missed)
app/                    Flutter app: lib/, test/ (unit + widget), test_e2e/ (host e2e vs backend: own account,
                        scoped sync, relatives), integration_test/ + test_driver/ (emulator journeys, flutter drive)
infra/                  docker-compose.yml, .env.example
docs/                   TZ.md, spec/, adr/
.github/workflows/      backend.yml, core.yml, app.yml, app-emulator.yml, app-release.yml, app-ios.yml,
                        app-scaffold.yml, repo.yml; helper scripts in .github/scripts/
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
- `core.yml`: Dart format/analyze/test.
- `app.yml`: analyze, unit/widget tests, format, debug APK (also builds with synthetic push settings against the
  RuStore SDK stub); `e2e` job runs `test_e2e/` (own sync, scoped sync, relatives: roles, revoke, delete -> restore)
  on the host against the real backend, one file at a time (`--concurrency=1`, shared backend and log).
- `app-emulator.yml` (PRs touching `app/**`, `packages/**`; manual): Android 14 emulator (KVM, cached AVD),
  real backend, real notification plugin. One debug build of `app/integration_test/app_test.dart` is
  installed once and driven by `.github/scripts/emulator/run.sh` through phases (onboarding -> reminder
  fires with the app terminated, **Taken** tapped in the shade -> `taken` -> force stop -> `rearm` ->
  `sign_out` -> `relatives`). The phase and the verification code come from `.github/scripts/emulator/host_control.py`
  (runner, `10.0.2.2:8090`, test-only). The `relatives` phase (Phase 3): the signed-out app registers as a
  relative, the host plays the owner through the API (`POST /relatives/setup|open-link|revoke`,
  `relatives_host.py`) and opens the invite link with `adb shell am start` (explicit package, placeholder host
  `links-ru.pillpal.invalid`, no domain verification); preview, confirm, Family tab, day view with the privacy
  matrix, revoke, evicted after sync. It uses `flutter drive --keep-app-running`, because `flutter test`
  uninstalls the app after each run. Failures are annotations; screenshots, dumps, logcat and logs are the
  `emulator-journeys` artifact.
- `app-release.yml` (push to `main`, manual, PRs changing it or `app/android/app/build.gradle.kts`):
  release AAB + APK (`android-release` artifact). Secrets `ANDROID_KEYSTORE_BASE64` (base64 upload keystore),
  `ANDROID_KEY_ALIAS`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD` sign with the upload key; without
  them the builds are debug-signed. API URL: repo variable `PILLPAL_API_BASE_URL_RU` (https), else a placeholder.
- `app-ios.yml` (PRs touching `app/ios/**`, push to `main`, manual): `flutter build ios --debug --no-codesign`
  on macOS. iOS reminder scenarios are a manual checklist (`docs/phase2-plan.md`).
- `app-scaffold.yml`: regenerates missing platform folders / `app/pubspec.lock` on branches (Flutter is not
  available in the sandbox). New app dependency: edit `app/pubspec.yaml`, delete `app/pubspec.lock` in the same
  commit, push, then pull the bot's lockfile commit.
- **No CD yet by owner's choice** (no store upload, no deploy). The backend image is built on every run but pushed to
  `ghcr.io/<owner>/pillpal-backend` only on push to `main` when the repo variable `PUBLISH_IMAGES=true`
  (Settings -> Secrets and variables -> Actions -> Variables). Leave it unset until deployments start.
- Docker: `backend/Dockerfile` runs `alembic upgrade head` on start only if `RUN_MIGRATIONS=1`; health `/healthz`,
  readiness `/readyz`.

## Do not
Edit `README.md` (owner-managed) or `docs/TZ.md` unprompted; commit `.env`/secrets; mock the database;
change schedule semantics in one implementation only; add medical fields to logs or analytics.
