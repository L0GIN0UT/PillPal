---
name: tdd-workflow
description: Use this skill when writing new features, fixing bugs, or refactoring in PillPal (FastAPI backend, pure-Dart pillpal_core, Flutter app). Enforces test-first development with pytest on real PostgreSQL, dart test, and the shared schedule vectors; backend coverage gate 85%.
---

# TDD workflow (PillPal)

## When to activate
New endpoint, service, sync rule, schedule-engine behaviour, Dart model, widget, or any bug fix.

## Loop
1. **Name the behaviour** in one sentence ("pull returns has_more=false when exactly limit rows remain").
2. **RED** — write the test, run it, confirm it fails on the assertion.
3. **GREEN** — minimal code to pass.
4. **REFACTOR** — clean up; rerun the module's tests.
5. Next behaviour. At the end: `/verify`.

## Where tests go
| Change | Test location | Style |
|---|---|---|
| Pure logic (`backend/app/domain/**`) | `backend/tests/domain/` | plain unit, no fixtures |
| Endpoint / service / migration | `backend/tests/test_*.py` | `client` fixture, real PostgreSQL + Redis |
| Schedule semantics | `spec/schedule-vectors/*.json` + both runners | vector is the test |
| `pillpal_core` | `packages/pillpal_core/test/` | `dart test`, fake clock/tz |
| App widget / provider (Phase 2) | `app/test/` | `ProviderScope(overrides:)`, in-memory drift |
| Journey | `app/integration_test/` / `backend/tests/e2e/` | see `e2e-runner` |

## Backend test template
```python
async def test_foreign_medication_is_404(client: AsyncClient) -> None:
    owner = await register(client)
    intruder = await register(client)
    med = await create_medication(client, owner)
    resp = await client.get(f"/v1/medications/{med['id']}", headers=intruder.headers)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"
```
Helpers: `tests/helpers.py` (`register`, `medication_payload`, `create_medication`, `daily_rule`, `create_schedule`).

## Required cases per endpoint
happy path · 422 validation · 401 no/expired token · foreign id -> 404 · idempotent replay (writes) · limit cap (lists).

## Rules
- Real DB, no mocks of SQLAlchemy/Alembic/Redis. Mock only email, push providers, clock.
- No `sleep`; inject time. Synthetic data only (no real names/prescriptions).
- Dart cannot run in the sandbox: write the test, reason it through, mark "verified in CI".
