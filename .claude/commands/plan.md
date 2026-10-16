---
description: Restate requirements, map impact across backend/core/spec/app, and produce a test-first step plan via the planner agent. WAIT for user confirmation before touching code.
---

# /plan

Invoke the **planner** agent for: $ARGUMENTS

1. Read `docs/TZ.md` (respect the current phase in §5), `CLAUDE.md`, `.claude/rules/*.md`, and the affected code.
2. Restate requirements; list assumptions and blocking questions.
3. Map impact: `backend/`, `packages/pillpal_core/`, `spec/`, `docs/spec/`, `app/`, `infra/`, `.github/`.
4. Steps in dependency order (spec -> vectors -> Python -> Dart -> API -> client), each with the failing test first.
5. Name the reviewer agents required (schedule / sync / notifications / privacy / security).
6. Done-when = `/verify` green.

**Stop after the plan.** Do not write code until the user says yes (the owner may answer in Russian: "да", "ок", "поехали").
To change the plan, the user replies with edits; re-plan, do not start coding.
