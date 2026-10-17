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

Tables that tie two accounts together (``profile_grants``, ``invites``) name the
column of the party whose personal data the row is; the other party's side
disappears with the profile they point at.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

DataKind = Literal["personal", "medical", "system"]
OwnerRef = Literal["user", "profile", "medication"]


@dataclass(frozen=True)
class TableInfo:
    kind: DataKind
    owner_column: str | None
    owner_ref: OwnerRef = "user"


@dataclass(frozen=True)
class KeyspaceInfo:
    kind: DataKind
    holds: str


TABLE_CLASSIFICATION: dict[str, TableInfo] = {
    "alembic_version": TableInfo("system", None),
    "users": TableInfo("personal", "id"),
    "devices": TableInfo("personal", "user_id"),
    "refresh_tokens": TableInfo("personal", "user_id"),
    "email_codes": TableInfo("personal", "user_id"),
    "profiles": TableInfo("personal", "owner_user_id"),
    "medications": TableInfo("medical", "profile_id", "profile"),
    "schedules": TableInfo("medical", "medication_id", "medication"),
    "dose_events": TableInfo("medical", "profile_id", "profile"),
    # The journal records which entity changed when: medical metadata.
    "sync_changes": TableInfo("medical", "profile_id", "profile"),
    # Who may see whose profile, with the disclosure version the owner confirmed.
    "profile_grants": TableInfo("personal", "grantee_user_id"),
    # Open and used invite links (only the token's hash); the creator's data.
    "invites": TableInfo("personal", "created_by_user_id"),
    # Device tokens of the account's installations (ADR 0008).
    "push_tokens": TableInfo("personal", "user_id"),
    # Queued pushes: ids only, but "a dose of this profile was missed" is medical metadata.
    # They are about the subject profile (this owner column) and addressed to a recipient
    # (``recipient_user_id``): erasing either side deletes the row.
    "push_outbox": TableInfo("medical", "subject_profile_id", "profile"),
    # "A dose of this medication was missed at that time": medical metadata about the profile.
    "missed_dose_alerts": TableInfo("medical", "profile_id", "profile"),
    # The detector's watermark: one row, no personal data.
    "detector_state": TableInfo("system", None),
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
