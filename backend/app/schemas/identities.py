"""Request and response models of ``/v1/me/identities`` (ADR 0017 section 6).

The provider's ``subject`` is never part of a response.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from app.domain.auth_providers import Platform
from app.schemas.reauth import (
    Assertion,
    AuthorizationCode,
    CodeVerifier,
    Nonce,
    ProviderName,
    ReauthProof,
)


class IdentityOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    provider: ProviderName
    email_at_link: str | None = Field(description="The address the provider asserted at link time")
    created_at: datetime
    last_used_at: datetime | None


class IdentitiesOut(BaseModel):
    items: list[IdentityOut]


class LinkIdentityRequest(ReauthProof):
    """The new identity's assertion (nonce purpose ``link``) plus the re-auth proof of the
    signed-in account (``password`` or ``reauth``, ADR 0017 section 8)."""

    provider: ProviderName
    platform: Platform
    assertion: Assertion = Field(description="ID token, or the authorization code (VK, Yandex)")
    nonce: Nonce | None = Field(
        default=None, description="The ``link`` nonce the server issued; ID-token providers"
    )
    code_verifier: CodeVerifier | None = Field(default=None, description="PKCE (code providers)")
    authorization_code: AuthorizationCode | None = Field(
        default=None,
        description="Apple only: exchanged by the server, the refresh token kept sealed",
    )
