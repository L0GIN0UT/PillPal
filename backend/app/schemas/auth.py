"""Request/response models for authentication and the current user."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
)
from pydantic.networks import validate_email

from app.config import Region
from app.domain.consents import BASELINE_KINDS
from app.schemas.consents import ConsentIn
from app.validators import DisplayName, IanaTimezone


def normalize_email(value: str) -> str:
    """The stored form of an address (registration, and operator lookups by e-mail)."""
    return validate_email(value)[1].lower()


def _lower(value: str) -> str:
    return value.lower()


# Validated address, lowercased (registration).
Email = Annotated[
    str, StringConstraints(strip_whitespace=True, max_length=320), AfterValidator(normalize_email)
]
# Lookup-only address: no format validation (a malformed address simply
# matches no account), lowercased.
LookupEmail = Annotated[
    str, StringConstraints(strip_whitespace=True, max_length=320), AfterValidator(_lower)
]
Password = Annotated[str, StringConstraints(min_length=8, max_length=128)]
Code = Annotated[str, StringConstraints(pattern=r"^[0-9]{6}$")]
Locale = Literal["ru", "en"]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=False)


class RegisterRequest(StrictModel):
    email: Email = Field(description="Case-insensitive; stored lowercased")
    password: Password
    region: Region = Field(description="Must match the region of this server")
    locale: Locale = "en"
    timezone: IanaTimezone = "UTC"
    display_name: DisplayName | None = None
    consents: list[ConsentIn] | None = Field(
        default=None,
        max_length=len(BASELINE_KINDS),
        description="The texts the user accepted; the current health data, terms and privacy "
        "versions are required when present (always, once the server requires consents)",
    )

    @field_validator("consents")
    @classmethod
    def _one_per_kind(cls, value: list[ConsentIn] | None) -> list[ConsentIn] | None:
        if value is not None and len({item.kind for item in value}) != len(value):
            raise ValueError("one entry per kind")
        return value


class LoginRequest(StrictModel):
    email: LookupEmail
    password: Annotated[str, StringConstraints(max_length=128)]


class RefreshRequest(StrictModel):
    refresh_token: Annotated[str, StringConstraints(min_length=1, max_length=256)]


class VerifyEmailRequest(StrictModel):
    email: LookupEmail
    code: Code
    # From the 202 of ``POST /v1/auth/oauth/sign-up``: without it the address is verified but no
    # provider identity is linked (ADR 0017 section 5).
    pending_token: Annotated[str, StringConstraints(min_length=16, max_length=128)] | None = None


class ResendVerificationRequest(StrictModel):
    email: LookupEmail


class DeleteAccountRequest(StrictModel):
    password: Annotated[str, StringConstraints(max_length=128)]


class RestoreRequest(StrictModel):
    restore_ticket: Annotated[str, StringConstraints(min_length=1, max_length=256)]
    # Optional on purpose: a request without the code is an authentication failure
    # (401 ``invalid_token``) like a wrong one, not a validation error that would say
    # "the ticket alone is not enough" only to somebody who holds a ticket.
    code: Annotated[str, StringConstraints(max_length=16)] | None = None


class PasswordResetRequest(StrictModel):
    email: LookupEmail


class PasswordResetConfirm(StrictModel):
    email: LookupEmail
    code: Code
    new_password: Password


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"  # noqa: S105
    expires_in: int


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    email_verified: bool
    # False for an account that signs in with a provider only (no password to re-enter).
    has_password: bool
    region: Region
    locale: Locale
    created_at: datetime


class VerificationSent(BaseModel):
    """Registration answer; identical whether or not the e-mail was already registered."""

    status: Literal["verification_sent"] = "verification_sent"


class OAuthVerificationSent(VerificationSent):
    """The 202 of an OAuth sign-up without a verified address.

    ``pending_token`` is returned with every such answer (also when the address already has an
    account, where it opens nothing), so the shape tells nothing about the address.
    """

    pending_token: str


class Accepted(BaseModel):
    status: Literal["accepted"] = "accepted"
