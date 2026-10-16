"""Request/response models for invites, grants and feature flags (ADR 0005, ADR 0009)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StringConstraints, model_validator

from app.db.relatives import GrantRole
from app.schemas.entities import ProfileKind
from app.validators import DisplayName

MAX_DISCLOSURE_VERSION = 2**31 - 1
MAX_TOKEN_LENGTH = 256


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


# --- invites ----------------------------------------------------------------------------------


class InviteCreate(Strict):
    id: uuid.UUID = Field(description="Client UUID: a lost response can be retried safely")
    role: GrantRole
    disclosure_version: Annotated[int, Field(strict=True, ge=1, le=MAX_DISCLOSURE_VERSION)] = Field(
        description="Version of the disclosure screen the owner confirmed"
    )


class InviteCreated(BaseModel):
    id: uuid.UUID
    role: GrantRole
    expires_at: datetime
    url: str = Field(description="Invite link with the token in the fragment; shown once")


class InviteOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    role: GrantRole
    created_at: datetime
    expires_at: datetime


class InviteList(BaseModel):
    items: list[InviteOut]


Token = Annotated[str, StringConstraints(min_length=1, max_length=MAX_TOKEN_LENGTH)]


class InviteTokenRequest(Strict):
    """Preview and accept: the token travels in the body, never in a URL."""

    token: Token


class InvitePreview(BaseModel):
    inviter_display_name: str | None
    profile_display_name: str
    profile_kind: ProfileKind
    role: GrantRole
    expires_at: datetime


# --- grants -----------------------------------------------------------------------------------


class OutgoingGrantOut(BaseModel):
    """A grant on a profile the caller owns."""

    id: uuid.UUID
    profile_id: uuid.UUID
    profile_display_name: DisplayName
    profile_kind: ProfileKind
    grantee_display_name: str | None
    role: GrantRole
    active: bool = Field(description="False while the grant gives no access (always true for now)")
    disclosure_version: int
    created_at: datetime


class IncomingGrantOut(BaseModel):
    """A grant the caller holds on someone else's profile."""

    id: uuid.UUID
    profile_id: uuid.UUID
    profile_display_name: DisplayName
    profile_kind: ProfileKind
    owner_display_name: str | None
    role: GrantRole
    notify_missed: bool
    created_at: datetime


class GrantList(BaseModel):
    outgoing: list[OutgoingGrantOut]
    incoming: list[IncomingGrantOut]


class GrantPatch(Strict):
    """The owner changes ``role``; the grantee changes ``notify_missed``; never both."""

    role: GrantRole | None = None
    notify_missed: StrictBool | None = None

    @model_validator(mode="after")
    def _exactly_one_field(self) -> GrantPatch:
        given = [name for name in ("role", "notify_missed") if name in self.model_fields_set]
        if len(given) != 1 or any(getattr(self, name) is None for name in given):
            raise ValueError("send exactly one of role (owner) or notify_missed (grantee)")
        return self


# --- features ---------------------------------------------------------------------------------


class FeaturesOut(BaseModel):
    soft_limits_enabled: bool
    relatives_limit: int | None = Field(
        description="Active grants on own profiles; null = no limit"
    )
    pdf_reports_limit: int | None = Field(description="PDF reports; null = no limit")
