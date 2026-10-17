"""Background jobs as plain async functions, run by the ARQ worker (``app.worker``).

Each job takes the session factory and the settings, plus an injectable ``now``, and returns
a small report. Nothing here depends on ARQ: scheduling, the failure-logging wrapper and the
JSON serializer live in ``app.worker``.
"""
