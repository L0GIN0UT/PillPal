---
description: Sync CLAUDE.md, backend/README.md, infra/.env.example, docs/spec and .claude commands with the current code and CI via the doc-updater agent.
---

# /update-docs

Invoke **doc-updater** for: $ARGUMENTS (default: changes since `main`).

1. `git diff --name-only main...HEAD` (or uncommitted) to find what changed.
2. Update only what the change affects:
   - env vars in `app/config.py` -> `infra/.env.example`, `backend/README.md`
   - endpoints -> route docstrings/summaries (OpenAPI), `backend/README.md` API table
   - commands in `.github/workflows/` -> `CLAUDE.md`, `.claude/commands/verify.md`
   - schedule semantics -> only together with vectors (`schedule-engine-guardian`)
   - phase acceptance met -> "Current phase" in `CLAUDE.md`
3. Never edit `docs/TZ.md` or root `README.md` unless explicitly asked.
4. Report files changed and any code-vs-spec discrepancies found.
