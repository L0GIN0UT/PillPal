"""Which providers exist for this server (ADR 0017 section 1).

A provider is available only when ``FEATURE_OAUTH`` is on, the matrix allows it for the server's
region and the platform, and a verifier for it exists. The verifiers for Apple, Google, VK ID and
Yandex ID arrive with milestones 5.8 and 5.9; until then only the test double (dev and test) is
registered. The settings are read on every call, so a flag flipped in a test takes effect.
"""

from __future__ import annotations

from app.config import Settings
from app.domain.auth_providers import is_allowed, providers_for
from app.oauth.base import IdentityProvider
from app.oauth.fake import FakeProvider


class ProviderRegistry:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._fakes: dict[str, FakeProvider] = {}

    def _verifier(self, name: str) -> IdentityProvider | None:
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
        return self._verifier(name)

    def available(self, platform: str) -> list[str]:
        return [
            name
            for name in providers_for(self._settings.region, platform)
            if self.get(name, platform) is not None
        ]
