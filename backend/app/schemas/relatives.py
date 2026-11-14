"""Request/response models for invites, grants and feature flags (ADR 0005, ADR 0009)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StringConstraints, model_validator

from app.db.relatives import GrantRole
from app.schemas.entities import ProfileKind
from app.validators import DisplayName, RelativeNoteText

MAX_DISCLOSURE_VERSION = 2**31 - 1
MAX_TOKEN_LENGTH = 256


DisclosureVersion = Annotated[int, Field(strict=True, ge=1, le=MAX_DISCLOSURE_VERSION)]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


# --- invites ----------------------------------------------------------------------------------


class InviteCreate(Strict):
    id: uuid.UUID = Field(description="Client UUID: a lost response can be retried safely")
    role: GrantRole
    disclosure_version: DisclosureVersion = Field(
        description="Version of the disclosure screen the owner confirmed"
    )


class InviteCreated(BaseModel):
    id: uuid.UUID
    role: GrantRole
    created_at: datetime = Field(
        description="Server time of creation: with expires_at the app counts down without skew"
    )
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


InviteState = Literal["open", "consumed", "expired", "revoked"]


class InviteStatus(BaseModel):
    """``GET /v1/invites/{id}`` for the invite's creator: no token, no link, no accepter."""

    id: uuid.UUID
    role: GrantRole
    state: InviteState
    created_at: datetime
    expires_at: datetime


Token = Annotated[str, StringConstraints(min_length=1, max_length=MAX_TOKEN_LENGTH)]


class InviteTokenRequest(Strict):
    """Preview and accept: the token travels in the body, never in a URL."""

    token: Token


class InvitePreview(BaseModel):
    inviter_display_name: str | None
    inviter_email_masked: str | None = Field(
        default=None,
        description="First character of the inviter's e-mail, *** and the domain (i***@mail.ru)",
    )
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
    grantee_profile_id: uuid.UUID | None = Field(
        default=None,
        description="The grantee's self profile: the key of the caller's note about them",
    )
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


class RelativeNoteOut(BaseModel):
    """The caller's private note about a relative (ADR 0020 section 4): only its author sees it."""

    profile_id: uuid.UUID
    note: str
    updated_at: datetime


class GrantList(BaseModel):
    outgoing: list[OutgoingGrantOut]
    incoming: list[IncomingGrantOut]
    notes: list[RelativeNoteOut] = Field(
        default_factory=list,
        description="The caller's notes about the subjects listed above (incoming profile_id, "
        "outgoing grantee_profile_id)",
    )


class RelativeNotePut(Strict):
    note: RelativeNoteText


class GrantPatch(Strict):
    """The owner changes ``role`` (with the disclosure version of the screen they confirmed);
    the grantee changes ``notify_missed``; never both. ``guardian`` is only ever granted by
    a guardian invite, not by this call."""

    role: GrantRole | None = None
    notify_missed: StrictBool | None = None
    disclosure_version: DisclosureVersion | None = None

    @model_validator(mode="after")
    def _exactly_one_change(self) -> GrantPatch:
        given = [name for name in ("role", "notify_missed") if name in self.model_fields_set]
        if len(given) != 1 or any(getattr(self, name) is None for name in given):
            raise ValueError("send exactly one of role (owner) or notify_missed (grantee)")
        if (given == ["role"]) != (self.disclosure_version is not None):
            raise ValueError("disclosure_version goes with role, and only with role")
        return self


# --- features ---------------------------------------------------------------------------------


class FeaturesOut(BaseModel):
    soft_limits_enabled: bool
    relatives_limit: int | None = Field(
        description="Active grants on own profiles; null = no limit"
    )
    pdf_reports_limit: int | None = Field(description="PDF reports; null = no limit")
    account_deletion_grace_days: int = Field(
        description="Erasure completes no later than this many days after a deletion request"
    )
    managed_archive_retention_days: int = Field(
        description="Days a managed profile archived for co-guardians is kept before its purge"
    )
    catalog_contributions_enabled: bool = Field(
        default=False,
        description="Whether the app may offer the contribution checkbox at link time (ADR 0015)",
    )
    data_export_enabled: bool = Field(
        default=False, description="Whether the account data export is available (ADR 0016)"
    )
    consent_required_kinds: list[str] = Field(
        default_factory=list,
        description="Consent kinds registration must carry; empty while the server does not "
        "require consents",
    )
