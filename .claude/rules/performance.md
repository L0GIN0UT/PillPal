# Performance and model selection

Adapted from everything-claude-code `rules/performance.md`. Tokens are a budget: pick the lightest model that
does the job, and keep the heavy model for decisions that are expensive to get wrong.

## Which model runs which agent
The `model:` line in each `.claude/agents/*.md` frontmatter is the source of truth. **Do not pass a `model`
override when spawning an agent** unless the owner asks for it.

| Tier | Agents | Why |
|---|---|---|
| `haiku` | `doc-updater` | Mechanical: reads code and syncs docs. |
| `sonnet` | `tdd-guide`, `e2e-runner`, `build-error-resolver`, `refactor-cleaner`, `notifications-specialist`, `code-reviewer`, `ui-consistency-reviewer` | Writing and reviewing code: best cost/quality for coding. |
| `opus` | `planner`, `architect`, `security-reviewer`, `privacy-compliance-reviewer`, `offline-sync-reviewer`, `schedule-engine-guardian` | Rare, read-only, high stakes: plans, ADRs, security, health-data privacy, sync convergence, schedule semantics. |

Escalate a writer to `opus` only after a `sonnet` attempt failed twice on the same problem, and say why.

## Spend less per milestone
- One implementing agent per PR. Reviewers run in parallel, once, on the finished diff; a second round only
  re-checks the blockers it reported (send it a message, do not spawn a new reviewer).
- Low-risk PRs (docs, copy, small UI) get `code-reviewer` only. The full reviewer set is for sync, auth,
  deletion, push, detector, migrations and privacy-relevant code (`rules/agents.md`).
- Give agents exact paths and the plan section to read instead of "read the whole repo".
- Batch CI fixes into one push: every push restarts all app workflows.

## Context
Avoid the last 20% of the context window for multi-file features; compact or split the milestone first.
