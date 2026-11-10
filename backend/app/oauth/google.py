"""Google Sign-In: the ID-token verifier (ADR 0017 section 3). Android and iOS.

The apps request the token for the server: ``aud`` is the server (web) client id and ``azp`` is the
client id of the platform that asked (the Android or the iOS one). Both must match exactly and
``azp`` must be present, so a platform the client merely claims cannot select a looser verifier;
a platform without its own client id, or a server without a server client id, is refused.
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


def google_client_ids(settings: Settings, platform: str) -> tuple[str, str] | None:
    """``(audience, authorized party)`` of ``platform``, or ``None`` (not offered there)."""
    server = settings.oauth_google_server_client_id
    client = {
        "android": settings.oauth_google_client_id,
        "ios": settings.oauth_google_ios_client_id,
    }.get(platform)
    if server is None or client is None:
        return None
    return server, client


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
        device_id: str | None = None,
    ) -> VerifiedIdentity:
        ids = google_client_ids(self._settings, platform)
        if ids is None:
            raise invalid_provider_token()
        audience, authorized_party = ids
        return await verify_id_token(
            assertion,
            jwks=self._jwks,
            provider=self.name,
            issuers=GOOGLE_ISSUERS,
            audience=audience,
            authorized_party=authorized_party,
            nonce=nonce,
            now=now,
            skew_seconds=self._settings.oauth_clock_skew_seconds,
        )
