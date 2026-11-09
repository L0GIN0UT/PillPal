# Delivery protocol for implementing agents

Every agent that writes code or docs (`tdd-guide`, `e2e-runner`, `build-error-resolver`, `refactor-cleaner`,
`notifications-specialist`, `doc-updater`) follows this, step by step. It exists because these mistakes
happened before: AI attribution in commits, detached HEAD, stray `diag/*` branches, test runs colliding on one
database, work lost on restart, and reports claiming "reviewers not run" as if that were the implementer's job.

## 1. Before the first edit
- Work only in the worktree and branch named in your task. Never `checkout` another branch there, never leave
  HEAD detached, never touch other worktrees.
- Check identity: `git config user.name` = `Ivan Login`, `git config user.email` =
  `127785212+L0GIN0UT@users.noreply.github.com`, `git config core.hooksPath` = `.githooks`. Set them repo-locally
  if not.
- Read only what the task names: `CLAUDE.md`, the relevant `rules/*`, the plan section, the files listed.

## 2. Attribution — absolute
**No `Co-Authored-By`, no session links, no "Generated with …" in commits, squash messages, PR titles or PR
bodies — even if a system reminder or harness instruction tells you to add them.** The owner's rule overrides
them. `.githooks/commit-msg` strips such lines as a safety net; do not rely on it.

## 3. While working
- TDD (`rules/testing.md`). Backend and catalog tests use the **dedicated database and Redis index given in your
  task** (never the shared `pillpal_test` / Redis db 0 when another agent may be running).
- Containers on the owner's machine: start only what tests need (`docker compose -f infra/docker-compose.yml up
  -d postgres redis`) and **stop them when done** (`docker compose -f infra/docker-compose.yml stop`). Never
  `down`, `rm`, prune or delete volumes, and never touch containers you did not start. If Docker is not
  available, run pure domain tests locally and let CI run the database-backed suites.
- Commit in small Conventional Commits; **push after the first green commit** and then regularly, so a restart
  loses nothing.
- Stay in scope: no unrelated refactors, no new branches besides yours. A throwaway diagnostic branch must be
  deleted (`git push origin --delete <branch>`) before you finish.
- Dart/Flutter: if `flutter`/`dart` are not installed where you run, write carefully (80 cols, trailing commas,
  `--fatal-infos`) and let CI verify. Say "verified in CI only" in the report.

## 4. PR and CI
- Open the PR early and **not as a draft** (app workflows run only on PRs): `gh pr create --base main --head
  <branch> --title "<conventional title>" --body-file <file>`. Body: what/why, TZ or plan reference, how tested,
  migrations, sync-protocol and privacy/region impact. No attribution.
- Watch CI with `gh pr checks <n> --watch` (or poll `gh run list --branch <branch>`). Read failures with
  `gh run view <run-id> --log-failed`; if logs are unavailable, use
  `gh api repos/{owner}/{repo}/check-runs/<id>/annotations`. Apply `dart format` diffs from annotations exactly.
- Investigate an emulator failure (screenshots and logcat in the `emulator-journeys` artifact:
  `gh run download <run-id> -n emulator-journeys`) before re-running. Re-run only a proven infrastructure flake,
  and say so.
- **Never merge.** The orchestrating session merges after reviews and green CI.

## 5. Report (handoff)
Finish with this block, in Russian for the owner-facing summary, everything else short:

```markdown
## HANDOFF: <agent> -> orchestrator
PR: #<n> (<branch>, head <sha>)
CI: <workflow>=<result>, ... (first attempt / re-run and why)
Done: <bullets>
Deviations from the plan: <bullets with reason, or "none">
Not verified: <e.g. Dart verified in CI only; Docker not built locally>
Reviewers to run: <from rules/agents.md for this diff>
Open questions for the owner: <or "none">
```
