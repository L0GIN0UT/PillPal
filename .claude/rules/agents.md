# Agents — which one when

Agents live in `.claude/agents/`. Use them without being asked when the trigger applies.
Run independent reviewers in parallel.

| Agent | Trigger |
|---|---|
| `planner` | Before any TZ phase task, feature, cross-package change or non-trivial refactor. |
| `architect` | Hard-to-reverse decisions: data model, sync protocol, regions, new dependency/infra. Writes ADRs. |
| `tdd-guide` | Implementing a feature or fixing a bug — test first. |
| `code-reviewer` | After writing/modifying code; before every commit/PR. |
| `security-reviewer` | Auth, tokens, endpoints, sync paths, input parsing, secrets, Docker, CI, deps. |
| `build-error-resolver` | `/verify` or CI red for non-test reasons (lint, types, lock, Docker, analyzer). |
| `e2e-runner` | Critical journeys: backend HTTP flows (Phase 1), Flutter `integration_test` (Phase 2+). |
| `refactor-cleaner` | Maintenance passes, dead code, oversized modules. |
| `doc-updater` | After API/config/schema/CI changes; `/update-docs`. |
| `schedule-engine-guardian` | Anything touching rules, occurrences, keys, tz/DST, `docs/spec/schedule.md`, `spec/`. |
| `offline-sync-reviewer` | Sync push/pull, `sync_changes`, LWW, tombstones, dose events, client outbox. |
| `notifications-specialist` | Local notifications, reminder levels, actions, alarms, background reschedule (Phase 2+). |
| `privacy-compliance-reviewer` | Personal/medical data storage, logging, analytics, regions, relatives, deletion/export. |

## Typical flows
- **Feature**: `planner` -> (confirm) -> `tdd-guide` -> domain reviewer(s) -> `code-reviewer` -> `/verify` -> PR.
- **Engine change**: `planner` -> vectors + spec -> Python + Dart -> `schedule-engine-guardian` -> `code-reviewer`.
- **Sync change**: `tdd-guide` -> `offline-sync-reviewer` + `security-reviewer` + `privacy-compliance-reviewer`.
- **Red CI**: `build-error-resolver` (tooling) or `tdd-guide` (behaviour).
