"""Error tracking settings (milestone 5.13), a mixin of ``app.config.Settings``.

One DSN per region deployment: a RU server is configured with the RU project's DSN and an EU
server with the EU one. There is deliberately no second DSN and no region switch here.
"""

from __future__ import annotations

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings


class SentrySettings(BaseSettings):
    # Unset or blank = the SDK is never initialized. The DSN is a (weak) secret: SecretStr.
    sentry_dsn: SecretStr | None = None
    # Performance tracing is off by default; errors are what the deployment needs.
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
        if not text.startswith(("https://", "http://")):
            # Never echo the value into the startup log.
            raise ValueError("SENTRY_DSN must be an http(s) URL")
        return text

    @field_validator("sentry_release", mode="before")
    @classmethod
    def _blank_release_is_none(cls, value: object) -> object:
        if isinstance(value, str):
            return value.strip() or None
        return value
