"""Protocol limits that are part of the wire contract (OpenAPI) or of lock behaviour.

They are constants, not ``Settings``: request schemas need them at import time and a
client may rely on them. Operational limits that differ per deployment live in
``app.config.Settings``.
"""

MAX_PUSH_MUTATIONS = 500
MAX_PULL_LIMIT = 500  # rows per pull page
MAX_PULL_SCOPES = 50  # scopes one POST /v1/sync/pull may request
MAX_CURSOR = 2**63 - 1  # sync_changes.seq is a BIGINT
MAX_LOCK_ATTEMPTS = 3  # re-resolve and relock when an owner changed (app.services.scopes)

# ``profiles.missed_alert_minutes`` CHECK (migration 0006); the detector's index ranges use them.
MIN_MISSED_ALERT_MINUTES = 5
MAX_MISSED_ALERT_MINUTES = 720

# ``medications.manual_ingredients`` CHECK (migration 0015) and the API schema.
MANUAL_INGREDIENTS_MAX = 10
# Upper bound of a contribution-checkbox text version (``gtin_link_consent_version``).
MAX_CONSENT_VERSION = 10_000
