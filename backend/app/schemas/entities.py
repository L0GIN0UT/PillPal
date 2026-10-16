"""Models for profiles, medications, schedules and dose events.

Create/patch models are strict (unknown fields rejected - no mass assignment
of ``version``, ``profile_id`` etc.). ``*Data`` models are the full-state
payloads used by sync push; ``*Out`` models are API/sync-pull representations.
"""

from __future__ import annotations

import re
import uuid
from datetime import date, datetime, time
from decimal import Decimal
from typing import Annotated, Any, Literal, Self

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    model_validator,
)

from app.validators import (
    ClientTimestamp,
    DisplayName,
    EventNote,
    IanaTimezone,
    Name200,
    Notes,
    ShortText,
    UnitText,
    UtcDatetime,
)

TzMode = Literal["local", "fixed"]
Privacy = Literal["shared", "anonymous", "hidden"]
ProfileKind = Literal["self", "managed"]
DoseEventType = Literal["taken", "skipped", "snoozed", "undo"]

_OCCURRENCE_KEY_RE = re.compile(
    r"^(?P<sid>[0-9a-fA-F-]{36})/(?P<date>\d{4}-\d{2}-\d{2})T(?P<time>\d{2}:\d{2})$"
)


def validate_occurrence_key(value: str) -> str:
    """``"{schedule_id}/{YYYY-MM-DD}T{HH:MM}"`` (TZ §4.2); schedule id lowercased."""
    match = _OCCURRENCE_KEY_RE.match(value)
    if match is None:
        raise ValueError("occurrence_key must look like '<schedule_id>/YYYY-MM-DDTHH:MM'")
    try:
        sid = uuid.UUID(match["sid"])
        date.fromisoformat(match["date"])
        time.fromisoformat(match["time"])
    except ValueError:
        raise ValueError("occurrence_key contains an invalid id, date or time") from None
    return f"{sid}/{match['date']}T{match['time']}"


def occurrence_schedule_id(key: str) -> uuid.UUID:
    return uuid.UUID(key.split("/", 1)[0])


OccurrenceKey = Annotated[str, Field(max_length=64), AfterValidator(validate_occurrence_key)]
StockCount = Annotated[Decimal, Field(ge=0, le=Decimal("999999999.999"), decimal_places=3)]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


# --- profiles ---------------------------------------------------------------


class ProfileCreate(Strict):
    id: uuid.UUID
    display_name: DisplayName
    timezone: IanaTimezone


class ProfileUpdate(Strict):
    display_name: DisplayName | None = None
    timezone: IanaTimezone | None = None


class ProfileData(Strict):
    """Full mutable state of a profile (sync push)."""

    kind: ProfileKind = "managed"
    display_name: DisplayName
    timezone: IanaTimezone


class ProfileOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    kind: ProfileKind
    display_name: str
    timezone: str
    version: int
    created_at: datetime
    updated_at: datetime


# --- medications --------------------------------------------------------------


class MedicationFields(Strict):
    name: Name200
    form: ShortText | None = None
    strength_text: ShortText | None = None
    notes: Notes | None = None
    tz_mode: TzMode = "local"
    fixed_tz: IanaTimezone | None = None
    stock_count: StockCount | None = None
    stock_unit: UnitText | None = None
    low_stock_days: Annotated[int, Field(ge=0, le=365)] | None = None
    privacy: Privacy = "shared"

    @model_validator(mode="after")
    def _fixed_tz_matches_mode(self) -> Self:
        if (self.tz_mode == "fixed") != (self.fixed_tz is not None):
            raise ValueError("fixed_tz is required when tz_mode is 'fixed' and forbidden otherwise")
        return self


class MedicationCreate(MedicationFields):
    id: uuid.UUID


class MedicationUpdate(Strict):
    """Partial update; the merged result is re-validated as MedicationFields."""

    name: Name200 | None = None
    form: ShortText | None = None
    strength_text: ShortText | None = None
    notes: Notes | None = None
    tz_mode: TzMode | None = None
    fixed_tz: IanaTimezone | None = None
    stock_count: StockCount | None = None
    stock_unit: UnitText | None = None
    low_stock_days: Annotated[int, Field(ge=0, le=365)] | None = None
    privacy: Privacy | None = None

    @model_validator(mode="after")
    def _no_null_for_required(self) -> Self:
        for field in ("name", "tz_mode", "privacy"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null")
        return self


class MedicationData(MedicationFields):
    """Full state of a medication (sync push)."""

    profile_id: uuid.UUID


class MedicationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    profile_id: uuid.UUID
    name: str
    form: str | None
    strength_text: str | None
    notes: str | None
    tz_mode: TzMode
    fixed_tz: str | None
    stock_count: Decimal | None
    stock_unit: str | None
    low_stock_days: int | None
    privacy: Privacy
    version: int
    created_at: datetime
    updated_at: datetime


# --- schedules ----------------------------------------------------------------


class ScheduleCreate(Strict):
    id: uuid.UUID
    rule: dict[str, Any] = Field(description="Schedule rule v1, see docs/spec/schedule.md")


class ScheduleUpdate(Strict):
    rule: dict[str, Any]


class ScheduleData(Strict):
    medication_id: uuid.UUID
    rule: dict[str, Any]


class ScheduleOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    medication_id: uuid.UUID
    rule: dict[str, Any]
    version: int
    created_at: datetime
    updated_at: datetime


# --- dose events --------------------------------------------------------------


class DoseEventData(Strict):
    medication_id: uuid.UUID
    type: DoseEventType
    at: ClientTimestamp = Field(description="When it happened (client clock)")
    occurrence_key: OccurrenceKey | None = None
    target_event_id: uuid.UUID | None = None
    note: EventNote | None = None

    @model_validator(mode="after")
    def _undo_has_target(self) -> Self:
        if (self.type == "undo") != (self.target_event_id is not None):
            raise ValueError("target_event_id is required for 'undo' and forbidden otherwise")
        return self


class DoseEventCreate(DoseEventData):
    id: uuid.UUID


class DoseEventOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    profile_id: uuid.UUID
    medication_id: uuid.UUID
    occurrence_key: str | None
    type: DoseEventType
    target_event_id: uuid.UUID | None
    at: datetime
    recorded_at: datetime
    device_id: str | None
    note: str | None


# --- lists --------------------------------------------------------------------


class ProfileList(BaseModel):
    items: list[ProfileOut]


class MedicationList(BaseModel):
    items: list[MedicationOut]


class ScheduleList(BaseModel):
    items: list[ScheduleOut]


class DoseEventList(BaseModel):
    items: list[DoseEventOut]


# --- sync ---------------------------------------------------------------------

SyncEntity = Literal["profile", "medication", "schedule", "dose_event"]
SyncOp = Literal["upsert", "delete"]
MAX_PUSH_MUTATIONS = 500
MAX_PULL_LIMIT = 500


class Mutation(Strict):
    entity: SyncEntity
    op: SyncOp
    id: uuid.UUID
    data: dict[str, Any] | None = None
    client_updated_at: UtcDatetime


class PushRequest(Strict):
    mutations: list[Mutation] = Field(max_length=MAX_PUSH_MUTATIONS)


class MutationResult(BaseModel):
    entity: SyncEntity
    id: uuid.UUID
    status: Literal["applied", "ignored_stale", "rejected"]
    code: str | None = None
    version: int | None = None


class PushResponse(BaseModel):
    results: list[MutationResult]


class Change(BaseModel):
    seq: int
    entity: SyncEntity
    id: uuid.UUID
    op: SyncOp
    data: dict[str, Any] | None = Field(description="Current state; null for tombstones")


class PullResponse(BaseModel):
    changes: list[Change]
    next_cursor: int
    has_more: bool
