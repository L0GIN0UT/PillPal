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
- Reviewer budget per PR (owner decision 2026-11-09):
  - Docs, copy, small UI, CI tweaks, and backend or catalog code that touches none of the areas below:
    `code-reviewer` only (sonnet).
  - Sync push/pull, auth/tokens, relatives and grants, deletion/erasure, consent records, push payloads,
    the missed-dose detector, migrations on personal-data tables: the domain reviewers from
    `rules/agents.md` (opus). Add `security-reviewer` only when the diff touches auth, tokens, new public
    endpoints, parsing of untrusted files, secrets, Docker or CI permissions; for sync-only diffs
    `offline-sync-reviewer` + `privacy-compliance-reviewer` are enough.
  - Re-checks after fixes go only to the reviewers that reported a blocker or HIGH, never the whole set.
- Give agents exact paths and the plan section to read instead of "read the whole repo".
- Batch CI fixes into one push: every push restarts all app workflows.
- The 30-minute emulator job runs only for changes that can alter the journeys (its `paths:` filter);
  do not touch `app/lib/**` in a backend PR just to keep things in sync.

## When a PR is mergeable (owner decision 2026-11-09)
Required = every check GitHub started on the PR head because of the PR's own paths. Merge as soon as all of
them are green; do not wait for, or re-run, workflows the PR does not trigger, and do not re-run other PRs'
CI until they are next in line. A check that failed for a proven infrastructure reason unrelated to the
diff (runner disk, GitHub startup failure / "workflow file issue" with zero jobs) is re-run once; it is
never skipped or merged red.

## Context
Avoid the last 20% of the context window for multi-file features; compact or split the milestone first.
