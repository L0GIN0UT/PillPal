"""Inventory of personal and medical data (``.claude/rules/privacy.md`` rule 7).

Every table and every Redis keyspace is classified here. A test fails on any table
that is not listed, so a new table cannot ship without a decision about erasure
(``app.services.erasure``) and, from Phase 5, export. ``owner_column`` is the column
that ties a row to the data subject's account, and ``owner_ref`` says what it points
at, so export and the erasure test can find the rows of one account without table
specific knowledge:

* ``user`` - the column holds a ``users.id``;
* ``profile`` - it holds a ``profiles.id`` (the profile's owner is the data subject);
* ``medication`` - it holds a ``medications.id`` (and so reaches a profile).

From Phase 5 every non-system table also carries an export decision (``export``,
``docs/spec/export.md``): ``rows`` means the account's rows are written to the archive
(``app.services.export_archive``) minus ``export_exclude`` columns; ``none`` needs an
``export_reason``. ``export_also`` lists extra ``(column, owner_ref)`` pairs whose rows belong
to the account as well (the grants and invites on a profile it owns, not only the ones it
holds or created).

Tables that tie two accounts together (``profile_grants``, ``invites``) name the
column of the party whose personal data the row is; the other party's side
disappears with the profile they point at.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

DataKind = Literal["personal", "medical", "system"]
OwnerRef = Literal["user", "profile", "medication"]
ExportMode = Literal["rows", "none"]


@dataclass(frozen=True)
class TableInfo:
    kind: DataKind
    owner_column: str | None
    owner_ref: OwnerRef = "user"
    export: ExportMode = "none"
    export_exclude: tuple[str, ...] = ()
    export_reason: str | None = None
    export_also: tuple[tuple[str, OwnerRef], ...] = ()


@dataclass(frozen=True)
class KeyspaceInfo:
    kind: DataKind
    holds: str


# What leaves the region besides the user's own devices and a delivery provider (ADR 0014 section
# 3): fields of aggregates, never rows. The GTIN link contribution adds **no table**: its source
# is ``medications`` (erased with the account), and an erasure lowers the next snapshot's counts.
# ``tests/test_personal_data.py`` ties the field list to ``Confirmation``.
OUTBOUND_AGGREGATES: dict[str, tuple[str, ...]] = {
    "catalog_gtin_confirmations": ("gtin", "product_id", "count"),
}

SYSTEM_EXPORT_REASON = "system table, no personal data"

TABLE_CLASSIFICATION: dict[str, TableInfo] = {
    "alembic_version": TableInfo("system", None, export_reason=SYSTEM_EXPORT_REASON),
    # Credentials and their bookkeeping (hash, change time, token watermark) are not exported.
    "users": TableInfo(
        "personal",
        "id",
        export="rows",
        export_exclude=("password_hash", "password_changed_at", "tokens_not_before"),
    ),
    "devices": TableInfo("personal", "user_id", export="rows"),
    # Session history (devices, times) is personal data; the token hash is a credential.
    "refresh_tokens": TableInfo(
        "personal", "user_id", export="rows", export_exclude=("token_hash",)
    ),
    "email_codes": TableInfo(
        "personal", "user_id", export_reason="one-time credentials (hashed codes), short lived"
    ),
    # Which version of which text the account accepted, and when (Phase 5.2a): a record of the
    # data subject's decisions, erased with the account (owner decision Q4).
    "consents": TableInfo("personal", "user_id", export="rows"),
    "profiles": TableInfo("personal", "owner_user_id", export="rows"),
    "medications": TableInfo("medical", "profile_id", "profile", export="rows"),
    "schedules": TableInfo("medical", "medication_id", "medication", export="rows"),
    "dose_events": TableInfo("medical", "profile_id", "profile", export="rows"),
    # The journal records which entity changed when: medical metadata.
    "sync_changes": TableInfo(
        "medical",
        "profile_id",
        "profile",
        export_reason="derived journal: the exported rows already carry the same facts",
    ),
    # Who may see whose profile, with the disclosure version the owner confirmed. Grants the
    # account holds and grants on the profiles it owns; the other party appears as an opaque id.
    "profile_grants": TableInfo(
        "personal",
        "grantee_user_id",
        export="rows",
        export_exclude=("granted_seq",),
        export_also=(("profile_id", "profile"),),
    ),
    # Open and used invite links (only the token's hash); the creator's data. Also invites on
    # the profiles the account owns and invites it consumed.
    # The token hash is a credential and is not exported.
    "invites": TableInfo(
        "personal",
        "created_by_user_id",
        export="rows",
        export_exclude=("token_hash",),
        export_also=(("profile_id", "profile"), ("consumed_by_user_id", "user")),
    ),
    # Device tokens of the account's installations (ADR 0008): provider and timestamps only,
    # the token is a delivery credential.
    "push_tokens": TableInfo("personal", "user_id", export="rows", export_exclude=("token",)),
    # What the account has earned (kind, source, validity): no medical context. Revoked and expired
    # rows are history of the same account and are exported as well (ADR 0018 section 1).
    "entitlements": TableInfo("personal", "user_id", export="rows"),
    # What an operator did to the account (ADR 0018 section 5). The rows about the account are
    # exported; the operator's handle, OS user and host are the operator's data, not the
    # subject's. On erasure the row stays for the operator's accountability, without the person:
    # ``target_user_id`` and ``object_id`` are nulled.
    "admin_audit": TableInfo(
        "personal",
        "target_user_id",
        export="rows",
        export_exclude=("actor", "os_user", "host"),
    ),
    # Campaigns of promo codes: a label and the keyed digest of each code, never the code and no
    # account (ADR 0018 section 3). Shared by all accounts, so not erased with one.
    "promo_codes": TableInfo("system", None, export_reason=SYSTEM_EXPORT_REASON),
    # Which account redeemed which code, when, and the entitlement it got: the account's own
    # record. The code appears as an opaque id. Erased with the account.
    "promo_redemptions": TableInfo("personal", "user_id", export="rows"),
    # The export requests and, for at most 24 hours, the encrypted archive itself (Phase 5.5,
    # ADR 0016 section 8): medical, deleted with a deletion request, never part of an archive.
    "data_exports": TableInfo(
        "medical",
        "user_id",
        export_reason="the export itself: encrypted, downloadable once, gone within 24 hours",
    ),
    # Queued pushes: ids only, but "a dose of this profile was missed" is medical metadata.
    # They are about the subject profile (this owner column) and addressed to a recipient
    # (``recipient_user_id``): erasing either side deletes the row.
    "push_outbox": TableInfo(
        "medical",
        "subject_profile_id",
        "profile",
        export_reason="transient delivery queue, purged within days",
    ),
    # "A dose of this medication was missed at that time": medical metadata about the profile.
    "missed_dose_alerts": TableInfo(
        "medical",
        "profile_id",
        "profile",
        export_reason="transient detector record, purged after 72 hours",
    ),
    # The detector's watermark: one row, no personal data.
    "detector_state": TableInfo("system", None, export_reason=SYSTEM_EXPORT_REASON),
}

# Key prefixes used in Redis. Nothing medical is ever stored there.
REDIS_KEYSPACES: dict[str, KeyspaceInfo] = {
    "rl:": KeyspaceInfo("system", "rate-limit counters keyed by a hash of IP and account"),
    # Value: the account id of a pending-deletion account, under sha256(ticket), TTL 600 s;
    # a restore also needs the mailed code, and the key dies with it (ADR 0010 §2).
    "rt:": KeyspaceInfo("personal", "restore tickets: account id under a hash of the ticket"),
    "lock:": KeyspaceInfo("system", "run locks of the worker jobs (a random token, short TTL)"),
    "arq:": KeyspaceInfo("system", "ARQ queue and cron bookkeeping: job ids only, no arguments"),
}
