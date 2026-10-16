"""Request/response models for authentication and the current user."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints
from pydantic.networks import validate_email

from app.config import Region
from app.validators import DisplayName, IanaTimezone


def _normalize_email(value: str) -> str:
    return validate_email(value)[1].lower()


def _lower(value: str) -> str:
    return value.lower()


# Validated address, lowercased (registration).
Email = Annotated[
    str, StringConstraints(strip_whitespace=True, max_length=320), AfterValidator(_normalize_email)
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


class LoginRequest(StrictModel):
    email: LookupEmail
    password: Annotated[str, StringConstraints(max_length=128)]


class RefreshRequest(StrictModel):
    refresh_token: Annotated[str, StringConstraints(min_length=1, max_length=256)]


class VerifyEmailRequest(StrictModel):
    code: Code


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
    region: Region
    locale: Locale
    created_at: datetime


class RegisterResponse(BaseModel):
    user: UserOut
    tokens: TokenPair


class Accepted(BaseModel):
    status: Literal["accepted"] = "accepted"
