"""Protocol limits that are part of the wire contract (OpenAPI) or of lock behaviour.

They are constants, not ``Settings``: request schemas need them at import time and a
client may rely on them. Operational limits that differ per deployment live in
``app.config.Settings``.
"""

MAX_PUSH_MUTATIONS = 500
MAX_PULL_LIMIT = 500  # rows per pull page, both pull endpoints
MAX_PULL_SCOPES = 50  # scopes one POST /v1/sync/pull may request
MAX_CURSOR = 2**63 - 1  # sync_changes.seq is a BIGINT
MAX_LOCK_ATTEMPTS = 3  # re-resolve and relock when an owner changed (app.services.scopes)
