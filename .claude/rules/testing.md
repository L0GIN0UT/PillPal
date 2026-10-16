# Testing

## TDD is mandatory
Red -> Green -> Refactor (see `tdd-workflow` skill, `tdd-guide` agent). A bug fix starts with a failing
regression test. CI blocks merge on any red test.

## Backend
- pytest on **real PostgreSQL 16 + Redis 7**. Never mock the DB, sessions, Alembic or Redis; never use SQLite.
- Local services: `docker compose -f infra/docker-compose.yml up -d postgres redis`
  (or native `service postgresql start` / `redis-server`), then create the `pillpal_test` database once.
  Never point tests at a dev/prod DB: the suite drops the `public` schema.
- The suite migrates the test DB with Alembic once per session and truncates per test (`tests/conftest.py`).
- Mock only true externals: email sender (`InMemoryEmailSender`), push providers, clock.
- Coverage gate: `--cov-fail-under=85` over `app/`. Domain logic (schedule engine, sync, auth) aims for ~100%.
- Every endpoint: happy path, 422, 401, foreign resource -> 404, idempotent replay where relevant.

## Dart
- `dart test` for `pillpal_core`; `flutter test` (unit + widget) and `integration_test/` on emulator for the app.
- Fake clock and time zone; in-memory drift (`NativeDatabase.memory()`); fake notification adapter.
- Dart/Flutter does not run in the Claude sandbox (pub.dev blocked): tests are verified in CI. Say so in reports.

## Shared schedule vectors
- `spec/schedule-vectors/*.json` are the executable spec for the engine (`docs/spec/schedule.md`).
- Both the Python reference and the Dart engine run **all** vectors; `python spec/validate_vectors.py` checks shape.
- Engine change = vector first, then both implementations, same PR (`schedule-engine-guardian`).
- Must cover: each rule kind, course boundaries, leap day, DST gap/overlap (Europe + America), `fixed` vs `local`.

## Smells (reject in review)
Mocking the unit under test; order-dependent tests; `sleep` for timing; asserting logs instead of behaviour;
giant JSON snapshots; skipped tests without an issue link.
