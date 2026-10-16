---
name: verification-loop
description: Use this skill before declaring any PillPal task done, before commits and PRs, and after fixing a CI failure. Runs the CI-equivalent checks (ruff, mypy, pytest with coverage on real PostgreSQL, vectors validation, Dart format/analyze/test, actionlint) and reports honestly what passed, failed, or could not run.
---

# Verification loop

## When to activate
After finishing a change, before `git commit`, before opening a PR, after `/build-fix`.

## Phases (stop at first FAIL, fix, restart from that phase)
1. **Services** — PostgreSQL 16 on :5432 and Redis on :6379 reachable (`pg_isready`, `redis-cli ping`).
2. **Backend lint/format** — `cd backend && uv run ruff check . && uv run ruff format --check .`
3. **Types** — `uv run mypy app` (strict).
4. **Tests + coverage** — `uv run pytest --cov=app --cov-fail-under=85` with CI env
   (`DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_test`, `REDIS_URL`, `REGION=ru`, `JWT_SECRET`).
5. **Vectors** — `python spec/validate_vectors.py` from repo root.
6. **Dart** — `cd packages/pillpal_core && dart pub get && dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos && dart test`.
   In the Claude sandbox: `SKIPPED (CI only)`.
7. **Workflows** — `actionlint` if `.github/` changed.
8. **Diff review** — `git diff --stat`; no stray files (`.env`, coverage, caches); no `print(`; no medical data in log calls.

## Honesty rules
- Never report a check as passed unless you ran it in this session and saw the output.
- Report counts (tests passed, coverage %), not adjectives.
- If a check cannot run (no Dart SDK, no Docker Hub), say exactly which and why.

## Output
```
VERIFICATION: PASS | FAIL
Backend lint OK | types OK | tests 140 passed, cov 92%
Vectors OK | Dart SKIPPED (CI only) | actionlint OK
Ready for PR: YES/NO
```
