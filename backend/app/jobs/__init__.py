"""Background jobs as plain async functions (called by tests today, by the ARQ worker in 3.4).

Each job takes the session factory and the settings, plus an injectable ``now``, and returns
a small report. Wiring into ARQ (cron, job wrapper, JSON serializer) is milestone 3.4
(``docs/phase3-plan.md``): nothing here depends on it.
"""
