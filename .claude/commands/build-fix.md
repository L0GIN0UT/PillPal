---
description: Fix failing lint/type/lock/analyzer/Docker/CI errors with minimal diffs via the build-error-resolver agent.
---

# /build-fix

Invoke **build-error-resolver** for: $ARGUMENTS (default: whatever `/verify` reported).

1. Reproduce with the exact failing command (from `/verify` or the CI log the user pasted).
2. Group errors by root cause; fix the root first; rerun after each group.
3. Max 3 attempts per error, then stop and report.
4. Never loosen ruff/mypy/analyzer config, delete tests, or add `Any`/`# type: ignore` without a code and reason.
5. Finish with `/verify quick` (+ the previously failing step) and report what changed.

If the failure is a behaviour/test failure, switch to `/tdd`. If it needs a design change, switch to `/plan`.
