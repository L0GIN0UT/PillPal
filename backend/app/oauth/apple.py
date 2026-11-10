"""Sign in with Apple: the ID-token verifier (ADR 0017 section 3). iOS only.

The audience is the configured client id (the bundle id of the app). The server-side code exchange
and the token revocation are in ``app.oauth.apple_tokens``.
"""

from __future__ import annotations

from datetime import datetime

from app.config import Settings
from app.oauth.base import VerifiedIdentity
from app.oauth.errors import invalid_provider_token
from app.oauth.idtoken import verify_id_token
from app.oauth.jwks import JwksCache

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_PLATFORM = "ios"


class AppleProvider:
    name = "apple"
    uses_nonce = True

    def __init__(self, settings: Settings, jwks: JwksCache) -> None:
        self._client_id = settings.oauth_apple_client_id
        self._skew = settings.oauth_clock_skew_seconds
        self._jwks = jwks

    async def verify(
        self,
        assertion: str,
        *,
        nonce: str | None,
        platform: str,
        code_verifier: str | None,
        now: datetime,
        device_id: str | None = None,
    ) -> VerifiedIdentity:
        if platform != APPLE_PLATFORM or self._client_id is None:
            raise invalid_provider_token()
        return await verify_id_token(
            assertion,
            jwks=self._jwks,
            provider=self.name,
            issuers=(APPLE_ISSUER,),
            audience=self._client_id,
            nonce=nonce,
            now=now,
            skew_seconds=self._skew,
        )
