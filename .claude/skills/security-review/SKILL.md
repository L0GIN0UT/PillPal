---
name: security-review
description: Use this skill when adding authentication, endpoints, sync paths, user input handling, secrets/config, file or PDF generation, deep links/invites, Docker or CI changes in PillPal. Provides a checklist covering OWASP API Top 10 as it applies to an offline-first health app with per-region deployments.
---

# Security review checklist

## When to activate
Any change to `backend/app/api|services|security*`, `config.py`, `Dockerfile`, `.github/workflows/`, auth or
token handling in the app, invites/deep links, new dependencies.

## Checklist
**AuthN**
- [ ] Argon2id hashing; verify in thread pool; uniform error for unknown email / wrong password.
- [ ] Access JWT: HS256 pinned, 15 min, `exp`/`sub`/region checked; secret from env, >= 32 chars.
- [ ] Refresh: opaque, hashed at rest, single use, rotation, reuse -> family revoked; logout revokes.
- [ ] Rate limits on register/login/refresh/codes; codes hashed, TTL, attempt-limited.

**AuthZ (BOLA first)**
- [ ] Every query scoped by owner/guardian/grant; foreign id behaves as missing (404).
- [ ] Sync push: foreign ids rejected; `profile_id`/`medication_id` in `data` checked.
- [ ] No mass assignment: `extra="forbid"`, server-controlled fields ignored.

**Input / output**
- [ ] Pydantic constraints (lengths, enums, UUIDs, IANA tz, `HH:MM`); rule validated against v1.
- [ ] Bound parameters only; no f-string SQL.
- [ ] `limit` capped; cursors are validated integers.
- [ ] Error envelope with stable codes; no traces, SQL, or echoed input.

**Data protection** (with `privacy-compliance-reviewer`)
- [ ] No medical data or tokens in logs/Sentry/analytics/push payloads.
- [ ] Region isolation preserved; nothing cross-region.

**Platform**
- [ ] Tokens in `flutter_secure_storage`; nothing sensitive in SharedPreferences or notification payloads.
- [ ] Invite tokens >= 128-bit random, single use, expiring, region-bound (Phase 3).

**Infra / supply chain**
- [ ] Docker non-root, slim base, no secrets in layers; `.dockerignore` excludes `.env`, `.venv`.
- [ ] Workflows: minimal `permissions`, no `pull_request_target` + PR checkout, secrets not available to forks.
- [ ] New deps justified; lockfile reviewed; `uvx pip-audit` clean (when network allows).

## Quick scans
```bash
cd backend && uv run ruff check --select S .
grep -rnE "text\(f|execute\(f" backend/app
grep -rnE "log.*(name|note|dose|email|token|password)" backend/app
```
