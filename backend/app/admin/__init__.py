"""Operator commands: ``python -m app.admin`` (ADR 0018 section 5).

There is no HTTP admin surface. The CLI runs inside a regional deployment with its database, only
through ``docker compose exec`` or ``run --rm`` on the regional host, never from CI. Every change
is written to ``admin_audit`` with account ids only (never an e-mail).
"""
