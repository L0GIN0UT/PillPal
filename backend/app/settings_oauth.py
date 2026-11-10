"""Settings of OAuth sign-in (ADR 0017), a mixin of ``app.config.Settings``.

Off by default. The provider matrix (``app.domain.auth_providers``) decides which providers a
region may have: Apple and Google settings are refused when ``REGION=ru`` and VK ID and Yandex ID
settings when ``REGION=eu``, in every environment, so no region ever holds a processor of the
other one (ADR 0017 section 11). Strict environments also refuse a partly configured provider.
Secrets have ``*_FILE`` variants, read by ``Settings`` together with the push secrets.
"""

from __future__ import annotations

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
    "google": ("oauth_google_client_id",),
    "vk_id": ("oauth_vk_client_id", "oauth_vk_client_secret", "oauth_vk_client_secret_file"),
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
    "google": (("oauth_google_client_id",),),
    "vk_id": (("oauth_vk_client_id",), ("oauth_vk_client_secret", "oauth_vk_client_secret_file")),
    "yandex_id": (
        ("oauth_yandex_client_id",),
        ("oauth_yandex_client_secret", "oauth_yandex_client_secret_file"),
    ),
}
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

    # EU only.
    oauth_apple_client_id: str | None = None
    oauth_apple_team_id: str | None = None
    oauth_apple_key_id: str | None = None
    oauth_apple_private_key: SecretStr | None = None
    oauth_apple_private_key_file: str | None = None
    oauth_google_client_id: str | None = None
    # RU only.
    oauth_vk_client_id: str | None = None
    oauth_vk_client_secret: SecretStr | None = None
    oauth_vk_client_secret_file: str | None = None
    oauth_yandex_client_id: str | None = None
    oauth_yandex_client_secret: SecretStr | None = None
    oauth_yandex_client_secret_file: str | None = None

    @field_validator(*_SETTING_NAMES, mode="before")
    @classmethod
    def _blank_oauth_is_unset(cls, value: object) -> object:
        return None if isinstance(value, str) and not value.strip() else value

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
        return self

    @model_validator(mode="after")
    def _strict_environments_wait_for_reauth(self) -> Self:
        # An OAuth-only account has no password, so until the OAuth re-auth form of milestone 5.7
        # exists it could neither delete its account nor export its data. 5.7 removes this gate.
        environment: str = getattr(self, "environment")  # noqa: B009
        if self.feature_oauth and environment in STRICT_ENVIRONMENTS:
            raise ValueError(
                "FEATURE_OAUTH must not be enabled when ENVIRONMENT=staging or prod "
                "until OAuth re-authentication (milestone 5.7) exists"
            )
        return self

    @model_validator(mode="after")
    def _fake_provider_is_for_development(self) -> Self:
        environment: str = getattr(self, "environment")  # noqa: B009
        if self.oauth_fake_provider and environment not in ("dev", "test"):
            raise ValueError("OAUTH_FAKE_PROVIDER is allowed only when ENVIRONMENT=dev or test")
        return self
