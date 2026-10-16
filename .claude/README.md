# .claude — Claude Code configuration for PillPal

Project-scoped agents, rules, commands and skills for a Flutter + FastAPI monorepo.
Entry point for Claude is the root `CLAUDE.md`; this folder holds the detail.

## Contents
| Path | What |
|---|---|
| `agents/` | Subagents. ECC-derived: `planner`, `architect`, `tdd-guide`, `code-reviewer`, `security-reviewer`, `build-error-resolver`, `e2e-runner`, `refactor-cleaner`, `doc-updater`. PillPal-specific: `schedule-engine-guardian`, `offline-sync-reviewer`, `notifications-specialist`, `privacy-compliance-reviewer`. |
| `rules/` | Always-on conventions: `coding-style`, `testing`, `security`, `privacy`, `git-workflow`, `agents` (which agent when). |
| `commands/` | Slash commands: `/plan`, `/tdd`, `/code-review`, `/verify` (mirrors CI), `/build-fix`, `/update-docs`. |
| `skills/` | `tdd-workflow`, `verification-loop`, `fastapi-patterns`, `flutter-patterns`, `security-review`. |

No hooks are configured: nothing in this folder executes scripts automatically.

## Attribution
Adapted from [everything-claude-code](https://github.com/affaan-m/everything-claude-code)
(fork used: `WorldFlowAI/everything-claude-code`), MIT License, © Affaan Mustafa and contributors.
The MIT license permits use, modification and redistribution provided the copyright and permission
notice are retained; this paragraph serves as that notice for the adapted files.

## How it was adapted
- **Stack swap.** TypeScript/Next.js/Playwright/npm content replaced with Python 3.12 + FastAPI + SQLAlchemy 2
  async + Alembic + uv + ruff + mypy (strict) + pytest on real PostgreSQL, and Dart/Flutter + riverpod + drift +
  flutter_local_notifications + flutter_test/integration_test.
- **Domain reviewers added** for the risky parts of a medication reminder: schedule semantics shared by two
  engines (vectors are the contract), offline-first sync (LWW, tombstones, idempotency, cursors), reliable local
  notifications (iOS 64-pending window, Android exact alarms, OEM battery killers), and health-data privacy
  (152-FZ per-region localization, GDPR Art. 9, no medical data in logs/analytics/Sentry).
- **`/verify` mirrors `.github/workflows/`** exactly; keep them in sync.
- **Dropped from ECC**: hooks, MCP configs, contexts, continuous-learning, codemaps, checkpoint/orchestrate/eval
  commands, frontend/ClickHouse skills — not relevant or would run scripts implicitly.
- **Sandbox note**: Dart/Flutter cannot run in the Claude environment (pub.dev blocked); agents must say
  "verified in CI only" instead of claiming Dart checks passed.

## Optional hook ideas (not enabled)
Add to `.claude/settings.json` only after review; each runs a command on your machine.
- `PostToolUse` on `Edit|Write` of `backend/**/*.py`: `uv run ruff format <file>` and `ruff check --fix`.
- `PostToolUse` on `*.dart`: `dart format <file>`.
- `PreToolUse` on `Bash(git commit*)`: block if staged files include `.env*` or match secret patterns.
- `PreToolUse` on `Edit` of `spec/schedule-vectors/**`: remind to update `docs/spec/schedule.md` and both engines.
- `Stop`: print a reminder to run `/verify` when backend files changed.
