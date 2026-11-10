"""The re-authentication form (ADR 0017 section 8), shared by account deletion, data export, and
identity link and unlink: exactly one of ``{password}`` or ``{reauth: {provider, platform,
assertion, nonce}}``.

Kept free of other schema modules so ``schemas.auth`` and ``schemas.exports`` can build on it.
"""

from __future__ import annotations

from typing import Annotated, Literal, Self

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from app.domain.auth_providers import Platform

# An ID token is a few KiB at most; a PKCE verifier is 43 to 128 characters (RFC 7636).
Assertion = Annotated[str, StringConstraints(min_length=1, max_length=8192)]
Nonce = Annotated[str, StringConstraints(min_length=16, max_length=128)]
CodeVerifier = Annotated[str, StringConstraints(min_length=43, max_length=128)]
# Apple authorization code (short, single use): the server trades it for the refresh token.
AuthorizationCode = Annotated[str, StringConstraints(min_length=1, max_length=2048)]
ProviderName = Literal["apple", "google", "vk_id", "yandex_id"]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=False)


class ReauthAssertion(_Strict):
    """A fresh assertion of an already linked identity (nonce purpose ``reauth``)."""

    provider: ProviderName
    platform: Platform
    assertion: Assertion = Field(description="ID token, or the authorization code (VK, Yandex)")
    nonce: Nonce | None = Field(
        default=None, description="The ``reauth`` nonce the server issued; ID-token providers"
    )
    code_verifier: CodeVerifier | None = Field(default=None, description="PKCE (code providers)")


class ReauthProof(_Strict):
    """Exactly one proof. A missing or doubled one is a 422 (like a missing password always was)."""

    password: Annotated[str, StringConstraints(max_length=128)] | None = Field(
        default=None, description="The account password (accounts that have one)"
    )
    reauth: ReauthAssertion | None = Field(
        default=None, description="Or a fresh assertion of a linked sign-in provider"
    )

    @model_validator(mode="after")
    def _exactly_one_proof(self) -> Self:
        if (self.password is None) == (self.reauth is None):
            raise ValueError("Send exactly one of password or reauth")
        return self
