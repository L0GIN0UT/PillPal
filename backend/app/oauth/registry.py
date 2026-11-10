"""Which providers exist for this server (ADR 0017 section 1).

A provider is available only when ``FEATURE_OAUTH`` is on, the matrix allows it for the server's
region and the platform, and a verifier for it exists. Apple and Google have a real verifier when
their client ids are configured (Google: one per platform); the verifiers for VK ID and Yandex ID
arrive with milestone 5.9. The test double (``OAUTH_FAKE_PROVIDER``, dev and test only) stands in
for a provider that has no real verifier. The settings are read on every call, so a flag flipped in
a test takes effect.

The registry owns the one HTTP client for provider calls (timeout ``OAUTH_HTTP_TIMEOUT_SECONDS``,
no redirects) and the JWKS caches; ``aclose`` is called at shutdown. ``transport`` is for tests.
"""

from __future__ import annotations

import httpx

from app.config import Settings
from app.domain.auth_providers import is_allowed, providers_for
from app.oauth.apple import APPLE_JWKS_URL, AppleProvider
from app.oauth.apple_tokens import AppleTokenClient
from app.oauth.base import IdentityProvider
from app.oauth.fake import FakeProvider
from app.oauth.google import GOOGLE_JWKS_URL, GoogleProvider, google_audience
from app.oauth.jwks import JwksCache
from app.services.data_encryption import DataKeyring
from app.services.provider_tokens import ProviderTokens


class ProviderRegistry:
    def __init__(
        self, settings: Settings, *, transport: httpx.AsyncBaseTransport | None = None
    ) -> None:
        self._settings = settings
        self._transport = transport
        self._http: httpx.AsyncClient | None = None
        self._fakes: dict[str, FakeProvider] = {}
        self._real: dict[str, IdentityProvider] = {}
        self._tokens: ProviderTokens | None = None

    def http_client(self) -> httpx.AsyncClient:
        if self._http is None:
            self._http = httpx.AsyncClient(
                timeout=self._settings.oauth_http_timeout_seconds,
                transport=self._transport,
                follow_redirects=False,
            )
        return self._http

    async def aclose(self) -> None:
        if self._http is not None:
            await self._http.aclose()
            self._http = None

    @property
    def tokens(self) -> ProviderTokens:
        """Exchange and revoke of provider refresh tokens (Apple); inert when not configured."""
        if self._tokens is None:
            self._tokens = ProviderTokens(
                AppleTokenClient.from_settings(self._settings, self.http_client()),
                DataKeyring.from_settings(self._settings),
            )
        return self._tokens

    def _jwks(self, url: str) -> JwksCache:
        return JwksCache(
            url,
            self.http_client(),
            ttl_seconds=self._settings.oauth_jwks_cache_seconds,
            refresh_cooldown_seconds=self._settings.oauth_jwks_refresh_cooldown_seconds,
        )

    def _real_verifier(self, name: str, platform: str) -> IdentityProvider | None:
        settings = self._settings
        if name == "apple" and settings.oauth_apple_client_id:
            return self._real.setdefault(name, AppleProvider(settings, self._jwks(APPLE_JWKS_URL)))
        if name == "google" and google_audience(settings, platform) is not None:
            return self._real.setdefault(
                name, GoogleProvider(settings, self._jwks(GOOGLE_JWKS_URL))
            )
        return None

    def _verifier(self, name: str, platform: str) -> IdentityProvider | None:
        real = self._real_verifier(name, platform)
        if real is not None:
            return real
        if self._settings.oauth_fake_provider:
            return self._fakes.setdefault(name, FakeProvider(name))
        return None

    def get(self, name: str, platform: str, *, for_reauth: bool = False) -> IdentityProvider | None:
        """The verifier, or ``None``: flag off, not allowed here, or not configured.

        ``for_reauth``: deletion and export are rights, so proving with an already linked
        provider keeps working when ``FEATURE_OAUTH`` is switched off (ADR 0017 section 8).
        """
        if not self._settings.feature_oauth and not for_reauth:
            return None
        if not is_allowed(self._settings.region, name, platform):
            return None
        return self._verifier(name, platform)

    def available(self, platform: str) -> list[str]:
        return [
            name
            for name in providers_for(self._settings.region, platform)
            if self.get(name, platform) is not None
        ]
