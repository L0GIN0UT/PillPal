---
description: Run the same checks as CI (backend ruff/format/mypy/pytest+coverage, vectors validation, Dart format/analyze/test, actionlint) and print a PASS/FAIL report.
---

# /verify

Mode: $ARGUMENTS — `quick` (lint + types only), `full` (default), `pre-pr` (full + security scan).
Mirror `.github/workflows/*.yml`; if they change, update this file.

## 0. Services (backend tests need them)
```bash
pg_isready -h localhost -p 5432 || service postgresql start        # or: docker compose -f infra/docker-compose.yml up -d postgres redis
redis-cli -p 6379 ping || redis-server --daemonize yes
psql -h localhost -U postgres -lqt | cut -d'|' -f1 | grep -qw pillpal_test || createdb -h localhost -U postgres pillpal_test
```

## 1. Backend — `cd backend`
```bash
export DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_test
export REDIS_URL=redis://localhost:6379/0 REGION=ru JWT_SECRET=ci-secret-not-for-prod-ci-secret-not-for-prod
uv sync --frozen
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest --cov=app --cov-fail-under=85
```

## 2. Shared vectors — repo root
```bash
python spec/validate_vectors.py
```

## 3. Core (Dart) — `cd packages/pillpal_core`
```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```
Dart is unavailable in the Claude sandbox: report `SKIPPED (CI only)` — never claim it passed.

## 4. CI config (if `.github/` changed)
```bash
actionlint      # pip install actionlint-py
```

## 5. Hygiene (`full`, `pre-pr`)
```bash
git status --short
grep -rnE "print\(|breakpoint\(" backend/app
grep -rnE "(password|secret|token)\s*=\s*['\"][^'\"]{8,}" backend/app packages --include=*.py --include=*.dart
```
`pre-pr`: also `cd backend && uv run ruff check --select S .` and run `security-reviewer` on the branch diff.

## Report
```
VERIFICATION: PASS | FAIL
Backend:  ruff OK | format OK | mypy OK | pytest 123 passed, cov 91%
Vectors:  OK (N files)
Core:     SKIPPED (CI only) | OK
CI:       actionlint OK | n/a
Hygiene:  OK | <findings>
Ready for PR: YES | NO — <blocking items>
```
On a tooling failure suggest `/build-fix`; on a behaviour failure, `/tdd`.
