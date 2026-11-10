"""Request/response models of the OAuth sign-in routes (ADR 0017)."""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints, field_validator

from app.config import Region
from app.domain.auth_providers import Platform
from app.domain.consents import BASELINE_KINDS
from app.schemas.auth import Email, Locale, StrictModel
from app.schemas.consents import ConsentIn
from app.validators import DisplayName, IanaTimezone

NoncePurpose = Literal["sign_in", "link", "reauth"]
# An ID token is a few KiB at most; a PKCE verifier is 43 to 128 characters (RFC 7636).
Assertion = Annotated[str, StringConstraints(min_length=1, max_length=8192)]
Nonce = Annotated[str, StringConstraints(min_length=16, max_length=128)]
CodeVerifier = Annotated[str, StringConstraints(min_length=43, max_length=128)]
Ticket = Annotated[str, StringConstraints(min_length=1, max_length=256)]


class NonceRequest(StrictModel):
    purpose: NoncePurpose


class NonceOut(BaseModel):
    nonce: str = Field(description="Server-issued, single use; the token must carry its sha256")
    expires_in: int


class ProviderOut(BaseModel):
    provider: Literal["apple", "google", "vk_id", "yandex_id"]


class ProvidersOut(BaseModel):
    providers: list[ProviderOut]


class OAuthSignInRequest(StrictModel):
    platform: Platform
    assertion: Assertion = Field(description="ID token, or the authorization code (VK, Yandex)")
    nonce: Nonce | None = Field(
        default=None, description="The nonce the server issued; required by ID-token providers"
    )
    code_verifier: CodeVerifier | None = Field(default=None, description="PKCE (code providers)")


class OAuthSignUpRequest(StrictModel):
    signup_ticket: Ticket
    region: Region = Field(description="Must match the region of this server")
    locale: Locale = "en"
    timezone: IanaTimezone = "UTC"
    display_name: DisplayName | None = None
    consents: list[ConsentIn] | None = Field(
        default=None,
        max_length=len(BASELINE_KINDS),
        description="As for registration: the current health data, terms and privacy versions",
    )
    email: Email | None = Field(
        default=None, description="Required when the provider did not verify an address"
    )

    @field_validator("consents")
    @classmethod
    def _one_per_kind(cls, value: list[ConsentIn] | None) -> list[ConsentIn] | None:
        if value is not None and len({item.kind for item in value}) != len(value):
            raise ValueError("one entry per kind")
        return value
