## What and why
<!-- One or two sentences. Link the TZ section (e.g. TZ §4.3) or issue. -->

## How it was tested
<!-- Commands run, new tests, anything verified only in CI (Dart/Flutter). -->

## Checklist
- [ ] Title follows Conventional Commits (`feat(backend): ...`)
- [ ] Tests written first; new behaviour and bug fixes are covered
- [ ] `/verify` passes locally (backend: ruff, format, mypy, pytest >= 85% coverage; vectors)
- [ ] Dart changes: `dart format`, `dart analyze --fatal-infos`, `dart test` green in CI
- [ ] Schedule semantics changed? -> `docs/spec/schedule.md` + `spec/schedule-vectors/` + Python + Dart updated together
- [ ] Sync changed? -> idempotent replay, LWW, tombstones, ownership tested
- [ ] DB migration? -> reversible, tested upgrade/downgrade, no long locks
- [ ] No medical data in logs, errors, analytics, Sentry or push payloads
- [ ] Region rules respected (no cross-region data or links)
- [ ] New env vars added to `infra/.env.example` and `backend/README.md`
- [ ] Docs updated (`CLAUDE.md`, READMEs, ADR if a decision was made)
- [ ] Reviewer agents run: <!-- e.g. code-reviewer, offline-sync-reviewer -->

## Notes for reviewers
<!-- Risks, follow-ups, screenshots for UI. -->
