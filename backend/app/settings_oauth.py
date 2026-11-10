"""Settings of OAuth sign-in (ADR 0017), a mixin of ``app.config.Settings``.

Off by default. The provider matrix (``app.domain.auth_providers``) decides which providers a
region may have: Apple and Google settings are refused when ``REGION=ru`` and VK ID and Yandex ID
settings when ``REGION=eu``, in every environment, so no region ever holds a processor of the
other one (ADR 0017 section 11). Strict environments also refuse a partly configured provider.
Secrets have ``*_FILE`` variants, read by ``Settings`` together with the push secrets.
"""

from __future__ import annotations

import re
from typing import Self

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings

from app.domain.auth_providers import PROVIDER_MATRIX
from app.settings_catalog import STRICT_ENVIRONMENTS

# Provider -> the settings that configure it (a ``*_file`` variant counts as the secret itself).
_PROVIDER_SETTINGS: dict[str, tuple[str, ...]] = {
    "apple": (
        "oauth_apple_client_id",
        "oauth_apple_team_id",
        "oauth_apple_key_id",
        "oauth_apple_private_key",
        "oauth_apple_private_key_file",
    ),
    "google": (
        "oauth_google_client_id",
        "oauth_google_ios_client_id",
        "oauth_google_server_client_id",
    ),
    "vk_id": (
        "oauth_vk_client_id",
        "oauth_vk_client_secret",
        "oauth_vk_client_secret_file",
        "oauth_vk_redirect_uri",
    ),
    "yandex_id": (
        "oauth_yandex_client_id",
        "oauth_yandex_client_secret",
        "oauth_yandex_client_secret_file",
    ),
}
# Groups that must be complete together in a strict environment (a secret or its ``_file``).
_COMPLETE_TOGETHER: dict[str, tuple[tuple[str, ...], ...]] = {
    "apple": (
        ("oauth_apple_client_id",),
        ("oauth_apple_team_id",),
        ("oauth_apple_key_id",),
        ("oauth_apple_private_key", "oauth_apple_private_key_file"),
    ),
    "google": (("oauth_google_client_id",), ("oauth_google_server_client_id",)),
    "vk_id": (("oauth_vk_client_id",), ("oauth_vk_client_secret", "oauth_vk_client_secret_file")),
    "yandex_id": (
        ("oauth_yandex_client_id",),
        ("oauth_yandex_client_secret", "oauth_yandex_client_secret_file"),
    ),
}
# Apple accepts a client secret valid for at most 6 months (15 777 000 s).
APPLE_CLIENT_SECRET_MAX_SECONDS = 15_777_000
# A setting that means nothing without another one of the same provider (strict check).
_REQUIRES: dict[str, str] = {"oauth_vk_redirect_uri": "oauth_vk_client_id"}
_REDIRECT_URI_RE = re.compile(r"^[a-z][a-z0-9+.-]*://[^\s]+$", re.IGNORECASE)
_SETTING_NAMES = tuple(name for names in _PROVIDER_SETTINGS.values() for name in names)


class OAuthSettings(BaseSettings):
    feature_oauth: bool = False
    # Test double for every provider the matrix allows (``app.oauth.fake``): dev and test only.
    oauth_fake_provider: bool = False
    oauth_nonce_ttl_seconds: int = Field(default=300, ge=30, le=3600)
    oauth_signup_ticket_ttl_seconds: int = Field(default=600, ge=60, le=3600)
    # A re-auth assertion must have been issued this recently (5.7).
    oauth_reauth_max_age_seconds: int = Field(default=300, ge=30, le=3600)
    oauth_http_timeout_seconds: float = Field(default=10.0, gt=0, le=60)
    # JWKS of Apple and Google: cached this long, refreshed once on an unknown ``kid`` (not more
    # often than the cooldown); ``iat`` may be this far in the future (skew with the provider).
    oauth_jwks_cache_seconds: int = Field(default=3600, ge=60, le=86400)
    oauth_jwks_refresh_cooldown_seconds: int = Field(default=30, ge=5, le=3600)
    # After the TTL the last keys keep serving this long while the provider cannot be reached.
    oauth_jwks_stale_seconds: int = Field(default=86400, ge=0, le=604800)
    # An unlink revokes inline with this short timeout; deletion never waits on Apple (a worker
    # sweep revokes).
    oauth_revoke_inline_timeout_seconds: float = Field(default=3.0, gt=0, le=30)
    oauth_clock_skew_seconds: int = Field(default=30, ge=0, le=300)
    # The ES256 client secret for Apple's token endpoint lives this long (Apple's limit: 6 months).
    oauth_apple_client_secret_ttl_seconds: int = Field(
        default=86400, ge=60, le=APPLE_CLIENT_SECRET_MAX_SECONDS
    )

    # EU only.
    oauth_apple_client_id: str | None = None
    oauth_apple_team_id: str | None = None
    oauth_apple_key_id: str | None = None
    oauth_apple_private_key: SecretStr | None = None
    oauth_apple_private_key_file: str | None = None
    # Google: the ID token ``aud`` is the server (web) client id and its ``azp`` is the client id
    # of the platform: ``OAUTH_GOOGLE_CLIENT_ID`` is the Android one. A platform without its own id
    # is not offered, so a client-claimed platform never selects a looser verifier.
    oauth_google_client_id: str | None = None
    oauth_google_ios_client_id: str | None = None
    oauth_google_server_client_id: str | None = None
    # RU only.
    oauth_vk_client_id: str | None = None
    oauth_vk_client_secret: SecretStr | None = None
    oauth_vk_client_secret_file: str | None = None
    # The redirect URI of the app's VK authorization (it must equal what the app sent to VK);
    # unset means VK's Android default ``vk<client id>://vk.ru/blank.html``.
    oauth_vk_redirect_uri: str | None = Field(default=None, max_length=512)
    oauth_yandex_client_id: str | None = None
    oauth_yandex_client_secret: SecretStr | None = None
    oauth_yandex_client_secret_file: str | None = None

    @field_validator(*_SETTING_NAMES, mode="before")
    @classmethod
    def _blank_oauth_is_unset(cls, value: object) -> object:
        return None if isinstance(value, str) and not value.strip() else value

    @field_validator("oauth_vk_redirect_uri")
    @classmethod
    def _redirect_uri_is_absolute(cls, value: str | None) -> str | None:
        if value is not None and not _REDIRECT_URI_RE.match(value):
            raise ValueError("OAUTH_VK_REDIRECT_URI must be an absolute URI (scheme://...)")
        return value

    def _configured(self, names: tuple[str, ...]) -> bool:
        return any(getattr(self, name) is not None for name in names)

    @model_validator(mode="after")
    def _providers_belong_to_the_region(self) -> Self:
        # ``region`` is declared by ``Settings``; the mixin is never instantiated alone.
        region: str = getattr(self, "region")  # noqa: B009
        allowed = PROVIDER_MATRIX.get(region, {})
        for provider, names in _PROVIDER_SETTINGS.items():
            if provider not in allowed and self._configured(names):
                raise ValueError(
                    f"OAUTH_{provider.upper()}_* settings are not allowed when REGION={region}"
                )
        return self

    @model_validator(mode="after")
    def _strict_environments_refuse_partial_providers(self) -> Self:
        environment: str = getattr(self, "environment")  # noqa: B009
        if environment not in STRICT_ENVIRONMENTS:
            return self
        for provider, groups in _COMPLETE_TOGETHER.items():
            present = [self._configured(group) for group in groups]
            if any(present) and not all(present):
                raise ValueError(f"OAuth provider {provider} is partially configured")
        for name, needed in _REQUIRES.items():
            if getattr(self, name) is not None and getattr(self, needed) is None:
                raise ValueError(f"{name.upper()} requires {needed.upper()}")
        return self

    @model_validator(mode="after")
    def _apple_needs_the_keyring(self) -> Self:
        """The Apple refresh token is stored encrypted: no keyring, no Apple in a strict setup."""
        environment: str = getattr(self, "environment")  # noqa: B009
        keys: dict[int, SecretStr] = getattr(self, "data_encryption_keys")  # noqa: B009
        if environment in STRICT_ENVIRONMENTS and self.oauth_apple_client_id and not keys:
            raise ValueError("OAUTH_APPLE_* requires DATA_ENCRYPTION_KEYS (refresh token at rest)")
        return self

    @model_validator(mode="after")
    def _apple_key_is_a_p256_pem(self) -> Self:
        """A broken Apple key stops a strict start instead of failing the first deletion."""
        environment: str = getattr(self, "environment")  # noqa: B009
        key = self.oauth_apple_private_key
        if environment in STRICT_ENVIRONMENTS and key is not None:
            from app.oauth.apple_key import load_apple_key

            if load_apple_key(key.get_secret_value()) is None:
                raise ValueError("OAUTH_APPLE_PRIVATE_KEY is not a P-256 PEM private key")
        return self

    @model_validator(mode="after")
    def _fake_provider_is_for_development(self) -> Self:
        environment: str = getattr(self, "environment")  # noqa: B009
        if self.oauth_fake_provider and environment not in ("dev", "test"):
            raise ValueError("OAUTH_FAKE_PROVIDER is allowed only when ENVIRONMENT=dev or test")
        return self
