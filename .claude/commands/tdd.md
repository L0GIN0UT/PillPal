---
description: Implement a change test-first (Red -> Green -> Refactor) via the tdd-guide agent, on real PostgreSQL for the backend and dart test for pillpal_core.
---

# /tdd

Invoke the **tdd-guide** agent for: $ARGUMENTS

1. Pick the next smallest behaviour. Write the test:
   - backend: `backend/tests/...` (integration on real DB via `client` fixture, or pure unit for `app/domain`)
   - core: `packages/pillpal_core/test/...`
   - schedule semantics: a new vector in `spec/schedule-vectors/` + `docs/spec/schedule.md` text first
2. Run it and show the failure (must fail on the assertion, not on import):
   `cd backend && uv run pytest tests/<file>::<test> -x`  |  `cd packages/pillpal_core && dart test -N "<name>"`
3. Minimal implementation -> green. Refactor -> still green.
4. Repeat for error paths, auth (401/404 foreign), idempotent replay, edge cases from the tdd-guide checklist.
5. Finish with `/verify`. Dart is verified in CI only — say so.
