"""Error tracking settings (milestone 5.13), a mixin of ``app.config.Settings``.

One DSN per region deployment: a RU server is configured with the RU project's DSN and an EU
server with the EU one. There is deliberately no second DSN and no region switch here.
"""

from __future__ import annotations

from urllib.parse import urlparse

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings


def check_dsn_shape(dsn: str) -> None:
    if not dsn.startswith(("https://", "http://")):
        # Never echo the value into the startup log.
        raise ValueError("SENTRY_DSN must be an http(s) URL")


def check_dsn_hosting(dsn: str, *, region: str, strict_environment: bool) -> None:
    """Where the DSN may point (``rules/privacy.md`` 3): the tracker is a processor of the region.

    RU events must stay in Russia (152-FZ), so Sentry's hosted service is refused there; the
    operator runs a self-hosted Sentry in the region. Staging and prod must use TLS.
    """
    check_dsn_shape(dsn)
    parsed = urlparse(dsn)
    host = (parsed.hostname or "").lower()
    if not host:
        raise ValueError("SENTRY_DSN must be an http(s) URL")
    if region == "ru" and (host == "sentry.io" or host.endswith(".sentry.io")):
        raise ValueError("SENTRY_DSN must not point to sentry.io when REGION=ru (152-FZ)")
    if strict_environment and parsed.scheme != "https":
        raise ValueError("SENTRY_DSN must be https when ENVIRONMENT=staging or prod")


class SentrySettings(BaseSettings):
    # Docker secret variant (the DSN is a weak secret); read by ``Settings``.
    sentry_dsn_file: str | None = None
    # Unset or blank = the SDK is never initialized. The DSN is a (weak) secret: SecretStr.
    sentry_dsn: SecretStr | None = None
    # Performance tracing is off by default; errors are what the deployment needs. Staging and
    # prod refuse a rate above 0 (``Settings``): spans carry device tokens and Redis keys.
    sentry_traces_sample_rate: float = Field(default=0.0, ge=0.0, le=1.0)
    # An image tag or commit sha; blank = no release.
    sentry_release: str | None = Field(default=None, max_length=200)

    @field_validator("sentry_dsn", mode="before")
    @classmethod
    def _blank_dsn_is_none(cls, value: object) -> object:
        if value is None:
            return None
        text = value.get_secret_value() if isinstance(value, SecretStr) else str(value)
        text = text.strip()
        if not text:
            return None
        check_dsn_shape(text)
        return text

    @field_validator("sentry_dsn_file", mode="before")
    @classmethod
    def _blank_file_is_none(cls, value: object) -> object:
        return value.strip() or None if isinstance(value, str) else value

    @field_validator("sentry_release", mode="before")
    @classmethod
    def _blank_release_is_none(cls, value: object) -> object:
        if isinstance(value, str):
            return value.strip() or None
        return value
