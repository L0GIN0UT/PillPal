# Git workflow

## Branches
- `main` is always releasable and protected: no direct pushes.
- One branch per phase task or feature: `feat/phase1-sync-pull`, `fix/dst-overlap-key`, `chore/ci-cache`,
  `docs/schedule-spec`. Keep branches short-lived; rebase on `main` before opening/merging a PR.

## Commits — Conventional Commits
```
<type>(<scope>): <imperative summary, <= 72 chars>

<why, not what; reference TZ section or issue>
```
Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `ci`, `build`, `perf`.
Scopes: `backend`, `core`, `app`, `spec`, `infra`, `ci`, `claude`, `docs`.
Examples: `feat(backend): add cursor pagination to sync pull`, `test(spec): add DST overlap vectors for America/New_York`.
One logical change per commit; tests in the same commit as the code they cover.

## Pull requests
- Use the PR template checklist. Title follows the commit convention.
- Description: what/why, TZ reference, how tested, migrations, privacy/region impact.
- Run `/verify` locally and the relevant reviewer agents (`rules/agents.md`) before requesting review.
- **CI must be green before merge.** Do not merge with failing or skipped required checks.
- Squash-merge; the squash message follows the convention.
- Schedule semantics, sync protocol and DB migrations need an explicit note in the PR body.

## Attribution
The owner (Ivan, L0GIN0UT) is the only author and contributor. Commits are authored as
`Ivan Login <127785212+L0GIN0UT@users.noreply.github.com>`. Never add `Co-Authored-By`, session links or
"Generated with …" lines for AI tools to commits, squash messages or PR descriptions.

## Never
Force-push to `main`; commit `.env`, secrets, `.venv`, build output, coverage files; rewrite Alembic
revisions that are already on `main`.
