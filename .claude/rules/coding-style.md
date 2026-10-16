# Coding style

## General
- Small units: function <= 50 lines, file <= 400 lines, nesting <= 3. Split by domain, not by type.
- Names say what, not how. No abbreviations except `id`, `tz`, `db`, `dto`.
- No magic numbers: limits, minutes, TTLs live in `Settings` (backend) or a constants file (Dart).
- Comments explain *why*. Spec references as `TZ §4.2` or `docs/spec/schedule.md §3`.
- No `print` / `debugPrint`; use the structured logger (and see `privacy.md` for what may be logged).
- User-visible strings: backend returns stable error `code`s; the app localizes (RU + EN). No hard-coded UI text.

## Python (backend/)
- Python 3.12, `uv` only (no pip/poetry). Format + lint: `ruff format`, `ruff check` (config in `pyproject.toml`).
- `mypy --strict` clean. Full annotations; `Mapped[...]` columns; no `Any` crossing module boundaries.
- Async all the way: SQLAlchemy 2 `AsyncSession`, `asyncpg`, `redis.asyncio`. No blocking IO on the event loop
  (no `requests`, `time.sleep`, sync file IO); CPU-heavy work (Argon2) via `run_in_threadpool`/`to_thread`.
- Layers: `api/` (routers, HTTP only) -> `services/` (use cases, transactions) -> `db/` (models, queries);
  `domain/` is pure (schedule engine, LWW, validators) with no IO and no FastAPI imports.
- Pydantic v2 schemas in `schemas/` with `extra="forbid"` for inputs; explicit response models.
- Time: timezone-aware `datetime` only (`datetime.now(UTC)` via an injectable clock); `zoneinfo` for zones.
- Errors: raise domain errors mapped centrally in `errors.py` to `{"error": {"code", "message"}}`;
  no bare `except`, no swallowing, never echo user input in messages.
- DB invariants live in PostgreSQL (FK, UNIQUE, CHECK, triggers) and in Alembic migrations, never only in code.
- Migrations: one concern per revision, reversible `downgrade`, no data rewrite of large tables in one step.

## Dart (packages/pillpal_core, app/)
- `dart format` (default 80 cols), `dart analyze --fatal-infos` clean; lints from `analysis_options.yaml`.
- `pillpal_core`: pure Dart, no Flutter imports, no IO; clock and time zone are parameters.
- Immutable models (`final` fields, `const` constructors, `copyWith`); `==`/`hashCode` for value types.
- Null safety without `!` unless proven; avoid `late` except for DI-initialised fields.
- App (Phase 2): Riverpod for state/DI (no global singletons), drift for local DB (generated code committed? —
  no: run `build_runner`), widgets stay dumb — business logic in providers/services.
- `unawaited_futures` is an error; never use `BuildContext` across an `await` without `mounted` check.
- File names `snake_case.dart`; one public class per file where practical; `src/` for private library code.
