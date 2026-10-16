---
description: Review uncommitted changes (or the current branch vs main) with code-reviewer plus the domain reviewers the diff requires.
---

# /code-review

Scope: $ARGUMENTS (default: uncommitted changes; `branch` = `git diff main...HEAD`).

1. `git status --short`, `git diff --stat` (and `--cached`). Collect changed paths.
2. Run **code-reviewer** on the diff.
3. In parallel, run the domain reviewers the paths require:
   | Paths / topics | Agent |
   |---|---|
   | `spec/`, `docs/spec/schedule.md`, `app/domain/schedule`, `pillpal_core` engine | `schedule-engine-guardian` |
   | `api/sync`, `services/sync*`, `sync_changes`, dose events, drift outbox | `offline-sync-reviewer` |
   | notifications, alarms, background tasks | `notifications-specialist` |
   | logging, analytics, Sentry, personal/medical fields, regions, relatives | `privacy-compliance-reviewer` |
   | auth, tokens, new endpoints, config, Dockerfile, workflows, deps | `security-reviewer` |
4. Merge findings, dedupe, sort CRITICAL -> LOW with `file:line` and fix.
5. Verdict: APPROVE / APPROVE WITH COMMENTS / BLOCK. Any CRITICAL or HIGH = BLOCK.

Do not edit code during review unless the user asks.
