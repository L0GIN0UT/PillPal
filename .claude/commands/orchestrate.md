---
description: Run a milestone end to end with subagents - plan, implement in a worktree, review in parallel, fix, merge on green CI.
---

# /orchestrate <flow> <milestone or task>

Adapted from everything-claude-code `commands/orchestrate.md` for PillPal. The **main session is the
orchestrator**: it spawns agents, passes handoffs, runs reviewers and merges. Implementing agents cannot spawn
other agents and never merge (`rules/delivery.md`).

## Flows
| Flow | Sequence |
|---|---|
| `feature` | `planner` (only if the plan section is missing) -> `tdd-guide` -> reviewers -> fix round -> merge |
| `sync` | `tdd-guide` -> `offline-sync-reviewer` + `security-reviewer` + `privacy-compliance-reviewer` -> fix -> merge |
| `engine` | `tdd-guide` (vectors first) -> `schedule-engine-guardian` + `code-reviewer` -> fix -> merge |
| `ui` | `tdd-guide` -> `ui-consistency-reviewer` + `code-reviewer` (+ `privacy-compliance-reviewer` if relatives data is shown) -> fix -> merge |
| `bugfix` | `tdd-guide` (regression test first) -> `code-reviewer` -> merge |
| `docs` | `doc-updater` -> `code-reviewer` -> merge |

Reviewer choice per diff: `rules/agents.md`. Models: frontmatter only (`rules/performance.md`).

## Steps
1. **Prepare.** `git fetch`; create a worktree and branch per milestone:
   `git worktree add -b <type>/<milestone> ../pillpal-<short> origin/main`. Assign a dedicated test database
   name and Redis db index to the agent.
2. **Implement.** Spawn the implementing agent with: worktree path, branch, the plan section to read, the exact
   scope, owner decisions that apply, the test DB/Redis index, and "follow `.claude/rules/delivery.md`".
3. **Review.** When the agent's HANDOFF arrives with a PR and green CI, spawn the reviewers **in parallel**,
   read-only, pointing them at `git diff origin/main...origin/<branch>` and the plan section.
4. **Fix.** Send the collected findings back to the same implementing agent (SendMessage, not a new agent):
   blockers and should-fix items mandatory, nits optional. If a reviewer reported a blocker, ask that same
   reviewer to re-check only its blockers.
5. **Merge.** Verify: branch based on `origin/main`, every commit authored by Ivan Login, no attribution lines
   (`git log origin/main..<branch> --format=%B | grep -ciE "co-authored|claude.ai/code|generated with"` = 0),
   PR not draft, all checks green on the head SHA. Then squash-merge with an owner-only message:
   `gh pr merge <n> --squash --subject "<conventional title> (#<n>)" --body "<why, 1-3 sentences>"`.
6. **Clean up.** Remove the milestone's worktree and local branch; delete its remote branch (only branches this
   orchestration created); update the plan's status
   table; tell the owner in Russian what landed and what is next.

## Handoff format between agents
```markdown
## HANDOFF: <from> -> <to>
Context: <what was done>
Findings / decisions: <bullets>
Files: <changed files>
Open questions: <bullets or none>
Next: <what the receiver must do>
```

## Rules of thumb
- Independent milestones may run in parallel in separate worktrees; milestones that share migrations, the drift
  schema or emulator scripts run one at a time.
- Ask the owner (AskUserQuestion) only for product decisions; technical defaults are decided and recorded in
  the plan's decisions or Review log.
- Never re-implement a reviewer's job in the main session; never let an implementer merge.
