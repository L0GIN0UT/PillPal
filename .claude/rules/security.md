# Security

Before any commit touching auth, endpoints, sync, config, Docker or CI, run `security-reviewer`.

## Secrets
- Never commit secrets. Config comes from env (`Settings`); `.env` files are git-ignored; only
  `infra/.env.example` with obvious placeholders is committed.
- `JWT_SECRET` >= 32 chars, distinct per region and environment. CI uses a throwaway value.
- A leaked secret is rotated, not just deleted from history.

## Auth (TZ §3)
- Passwords: Argon2id. Access JWT 15 min, algorithm pinned, `exp`/`sub` validated, region-bound.
- Refresh tokens: opaque, stored hashed, single use, rotation, reuse revokes the family.
- Rate limit register/login/refresh/code endpoints. Same error for unknown email and wrong password.
- Mobile: tokens only in `flutter_secure_storage`.

## Authorization
- Every query is scoped by the caller (owner / guardian / grant). Foreign id == missing id (404).
- Client-supplied UUIDs (paths and sync payloads) are untrusted. Server-controlled fields are never read from input.

## Input & output
- Pydantic at the boundary, `extra="forbid"`, length limits, enums; schedule `rule` validated against v1.
- Parameterized SQL only (SQLAlchemy expressions / bound params). No f-strings in `text()`.
- Errors: stable codes, no stack traces, no SQL, no echoed input.
- `limit` capped server-side on all list/pull endpoints.

## Infra & CI
- Containers run as non-root; no secrets in image layers or build args.
- Workflows: least-privilege `permissions:`, no `pull_request_target` with PR checkout, pinned action majors,
  write permissions only on the job that needs them.
- Dependencies: Dependabot enabled; review lockfile diffs.
