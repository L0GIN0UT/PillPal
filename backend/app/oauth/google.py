"""Google Sign-In: the ID-token verifier (ADR 0017 section 3). Android and iOS.

Each platform has its own audience (the configured client id of that platform), so a platform the
client merely claims cannot select a looser one; a platform without a client id is refused. When
the token carries ``azp`` it must be the same client id.
"""

from __future__ import annotations

from datetime import datetime

from app.config import Settings
from app.oauth.base import VerifiedIdentity
from app.oauth.errors import invalid_provider_token
from app.oauth.idtoken import verify_id_token
from app.oauth.jwks import JwksCache

GOOGLE_ISSUERS = ("accounts.google.com", "https://accounts.google.com")
GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"


def google_audience(settings: Settings, platform: str) -> str | None:
    """The client id that audiences of ``platform`` must carry, or ``None`` (not offered)."""
    if platform == "android":
        return settings.oauth_google_client_id
    if platform == "ios":
        return settings.oauth_google_ios_client_id
    return None


class GoogleProvider:
    name = "google"
    uses_nonce = True

    def __init__(self, settings: Settings, jwks: JwksCache) -> None:
        self._settings = settings
        self._jwks = jwks

    async def verify(
        self,
        assertion: str,
        *,
        nonce: str | None,
        platform: str,
        code_verifier: str | None,
        now: datetime,
    ) -> VerifiedIdentity:
        audience = google_audience(self._settings, platform)
        if audience is None:
            raise invalid_provider_token()
        return await verify_id_token(
            assertion,
            jwks=self._jwks,
            provider=self.name,
            issuers=GOOGLE_ISSUERS,
            audience=audience,
            nonce=nonce,
            now=now,
            skew_seconds=self._settings.oauth_clock_skew_seconds,
        )
