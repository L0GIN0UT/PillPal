"""Scoped sync pull (ADR 0006 §2) and the redacted forms relatives receive (§3).

``MedicationRedacted`` and ``ScheduleRedacted`` document what the projection in
``app.domain.privacy`` produces for ``anonymous`` medications; the sync ``data``
field itself is free-form, so they are added to the OpenAPI snapshot for the
app's contract test (a test checks them against the projection).
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field

from app.domain.privacy import Role
from app.schemas.entities import Change, Strict, TzMode

MAX_CURSOR = 2**63 - 1  # sync_changes.seq is a BIGINT
MAX_PULL_SCOPES = 50
MAX_PULL_LIMIT = 500
ProfileKind = Literal["self", "managed"]

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
