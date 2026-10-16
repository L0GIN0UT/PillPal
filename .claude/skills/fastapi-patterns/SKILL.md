---
name: fastapi-patterns
description: Use this skill when adding or changing backend code in PillPal - FastAPI routers, dependencies, Pydantic v2 schemas, SQLAlchemy 2 async models and queries, Alembic migrations, Redis, settings, structured logging and error envelopes. Captures the project's layering and conventions.
---

# FastAPI patterns (backend/)

## Layout
```
app/main.py          create_app(settings) factory; ASGI entry app.main:app (lazy)
app/config.py        Settings (pydantic-settings, env only; REGION required)
app/api/             routers: HTTP concerns only (status codes, deps, response models)
app/services/        use cases; own the transaction; authorization scoping
app/db/              SQLAlchemy models, session factory
app/domain/          pure logic: schedule engine (Python reference), LWW, validators — no IO
app/schemas/         Pydantic v2 request/response models
app/errors.py        domain errors -> {"error": {"code", "message"}}
app/observability.py structlog JSON, request-id middleware
alembic/             migrations (alembic.ini in backend/)
```

## Routers (illustrative shape; follow existing code in `app/api/resources.py`)
```python
@router.get("/medications/{medication_id}", response_model=MedicationOut, summary="Get medication")
async def get_medication(medication_id: UUID, user: CurrentUser, session: SessionDep) -> MedicationOut:
    med = await entities.get_medication(session, user.id, medication_id)   # raises not_found() for foreign ids
    return MedicationOut.model_validate(med)
```
- Dependencies via `Annotated[..., Depends(...)]` aliases in `app/deps.py` (`CurrentUser`, `SessionDep`, `SettingsDep`, `RequiredDeviceId`).
- Path ids are client UUIDs; never trust them — the service scopes by user.

## Schemas
```python
class MedicationIn(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    id: UUID
    name: Annotated[str, StringConstraints(min_length=1, max_length=200)]
    privacy: Literal["shared", "anonymous", "hidden"] = "shared"
```
Server-controlled fields (`user_id`, `version`, `updated_at`, `seq`) never appear in input models.

## SQLAlchemy 2 async
- `Mapped[...]`/`mapped_column`; `select()` style; `AsyncSession` per request; `expire_on_commit=False`.
- Ownership in the query: `select(Medication).join(Profile).where(Profile.owner_user_id == user_id, Medication.id == mid)`.
- Avoid N+1: `selectinload` for collections; always `limit` lists.
- Idempotent inserts: `insert(...).on_conflict_do_nothing(index_elements=["id"])` (postgresql dialect).
- Invariants as constraints (CHECK on enums/ranges, UNIQUE, FK `ondelete`), dose events protected by trigger.

## Alembic
`cd backend && uv run alembic revision -m "add x"` (hand-written, review autogenerate output); reversible
`downgrade`; tests run upgrade -> downgrade -> upgrade. Never edit a revision merged to `main`.

## Errors & logging
- Raise `AppError(status, code, message)` or helpers (`not_found()`, `unauthorized()`) from `app.errors`;
  never `HTTPException` with free text containing user input. 404 for foreign ids, same as missing.
- `log = get_logger(__name__)`; `log.info("medication_created", medication_id=str(med.id))` — ids only, never names/notes.

## Config & runtime
- Add settings to `Settings` + `infra/.env.example` + `backend/README.md`.
- Health: `/healthz` (liveness), `/readyz` (DB + Redis). Docker runs `alembic upgrade head` only with `RUN_MIGRATIONS=1`.
