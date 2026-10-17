"""Sync wire models: push, pull, scoped pull (ADR 0006 §2) and the redacted forms (§3).

``MedicationRedacted`` and ``ScheduleRedacted`` document what the projection in
``app.domain.privacy`` produces for ``anonymous`` medications; the sync ``data``
field itself is free-form, so they are added to the OpenAPI snapshot for the
app's contract test (a test checks them against the projection).
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, Field, model_validator

from app.domain.privacy import Role
from app.limits import MAX_CURSOR, MAX_PULL_LIMIT, MAX_PULL_SCOPES, MAX_PUSH_MUTATIONS
from app.schemas.entities import ProfileKind, Strict, TzMode, require_canonical_uuid
from app.validators import UtcDatetime

SyncEntity = Literal["profile", "medication", "schedule", "dose_event"]
SyncOp = Literal["upsert", "delete"]


# Fields the server owns. A client echoing pulled state may send them back in
# ``data``; they are dropped before validation instead of failing it (anything
# else unknown is still rejected by ``extra="forbid"``).
SERVER_CONTROLLED_FIELDS = frozenset(
    {
        "id",
        "version",
        "created_at",
        "updated_at",
        "client_updated_at",
        "updated_by_device",
        "deleted_at",
        "owner_user_id",
    }
)
DOSE_EVENT_SERVER_FIELDS = SERVER_CONTROLLED_FIELDS | {"profile_id", "recorded_at", "device_id"}


def strip_server_fields(entity: str, data: dict[str, Any] | None) -> dict[str, Any] | None:
    if data is None:
        return None
    dropped = DOSE_EVENT_SERVER_FIELDS if entity == "dose_event" else SERVER_CONTROLLED_FIELDS
    return {k: v for k, v in data.items() if k not in dropped}


class Mutation(Strict):
    entity: SyncEntity
    op: SyncOp
    id: uuid.UUID
    data: dict[str, Any] | None = None
    client_updated_at: UtcDatetime

    @model_validator(mode="before")
    @classmethod
    def _schedule_id_is_canonical(cls, value: Any) -> Any:
        if isinstance(value, dict) and value.get("entity") == "schedule":
            require_canonical_uuid(value.get("id"))
        return value


class PushRequest(Strict):
    mutations: list[Mutation] = Field(max_length=MAX_PUSH_MUTATIONS)


class EntityState(BaseModel):
    """Current server state of an entity, including its conflict key."""

    op: SyncOp
    data: dict[str, Any] | None = Field(description="Current state; null for tombstones")
    client_updated_at: datetime | None = Field(
        description="Last-write-wins key (null for dose events, which are immutable)"
    )
    updated_by_device: str | None
    deleted_at: datetime | None


class MutationResult(BaseModel):
    entity: SyncEntity
    id: uuid.UUID
    status: Literal["applied", "ignored_stale", "rejected"]
    code: str | None = None
    version: int | None = None
    current: EntityState | None = Field(
        default=None,
        description="Server state to converge to (ignored_stale and key_conflict only)",
    )


class PushResponse(BaseModel):
    results: list[MutationResult]


class Change(EntityState):
    seq: int
    scope: uuid.UUID = Field(description="The profile (sync scope) this change belongs to")
    entity: SyncEntity
    id: uuid.UUID


Cursor = Annotated[int, Field(ge=0, le=MAX_CURSOR, strict=True)]


class ScopedPullRequest(Strict):
    cursors: dict[uuid.UUID, Cursor] = Field(
        min_length=1,
        max_length=MAX_PULL_SCOPES,
        description=(
            "Profile id -> last seq the client holds. Changes are returned only for "
            "these scopes; the client adds new scopes from the response at cursor 0."
        ),
    )
    limit: int = Field(default=100, ge=1, le=MAX_PULL_LIMIT)
    backfill_until: dict[uuid.UUID, Cursor] | None = Field(
        default=None,
        max_length=MAX_PULL_SCOPES,
        description=(
            "Profile id -> the ``backfill_until`` the server returned for that scope, echoed "
            "until the scope's cursor reaches it. Optional: without it a backfill still "
            "works, it just may receive deletes for medications it never held."
        ),
    )


class ScopeOut(BaseModel):
    profile_id: uuid.UUID
    role: Role
    kind: ProfileKind
    archived: bool
    archive_purge_after: datetime | None
    owner_last_seen_at: datetime | None = Field(
        description=(
            "When the owner's devices last synced, floored to the hour; only on a self "
            "profile that is not the caller's own"
        )
    )
    cursor: int | None = Field(
        description="The scope's cursor after this page; null when it was not requested"
    )
    backfill_until: int | None = Field(
        default=None,
        description=(
            "Set while a relative's backfill of this scope is unfinished (the cursor is below "
            "it): echo it in the next request. Null otherwise."
        ),
    )


class ScopedPullResponse(BaseModel):
    scopes: list[ScopeOut] = Field(description="Every scope the caller can access")
    revoked: list[uuid.UUID] = Field(
        description="Requested scopes the caller cannot access (never existed looks the same)"
    )
    changes: list[Change]
    has_more: bool


class MedicationRedacted(BaseModel):
    """An ``anonymous`` medication as a relative sees it: no name, notes or stock."""

    id: uuid.UUID
    profile_id: uuid.UUID
    privacy: Literal["anonymous"]
    tz_mode: TzMode
    fixed_tz: str | None
    redacted: Literal[True]


class RedactedSlot(BaseModel):
    time: str


class ScheduleRedactedRule(BaseModel):
    """The rule without doses: course dates and times are needed to expand occurrences."""

    v: int
    kind: str
    start_date: date
    end_date: date | None = None
    weekdays: list[int] | None = None
    interval_days: int | None = None
    times: list[RedactedSlot]


class ScheduleRedacted(BaseModel):
    id: uuid.UUID
    medication_id: uuid.UUID
    redacted: Literal[True]
    rule: ScheduleRedactedRule
