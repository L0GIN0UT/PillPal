"""Settings of the outgoing e-mail, a mixin of ``app.config.Settings`` (ADR 0008 style).

``EMAIL_BACKEND``: ``log`` drops the mail and logs an event (dev default), ``memory`` keeps it in
a list (tests), ``smtp`` delivers it. ``prod`` and ``staging`` refuse to start without ``smtp``
(see ``app.main``). The password has a ``SMTP_PASSWORD_FILE`` variant for Docker secrets; the file
is read by ``Settings`` together with the push secrets.
"""

from __future__ import annotations

from typing import Literal, Self

from email_validator import EmailNotValidError, validate_email
from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings

EmailBackend = Literal["log", "memory", "smtp"]
SmtpSecurity = Literal["ssl", "starttls"]

# Implicit TLS and submission-with-STARTTLS ports (RFC 8314, RFC 6409).
DEFAULT_SMTP_PORTS: dict[str, int] = {"ssl": 465, "starttls": 587}


class EmailSettings(BaseSettings):
    email_backend: EmailBackend = "log"
    smtp_host: str | None = None
    smtp_port: int | None = Field(default=None, ge=1, le=65535)
    smtp_security: SmtpSecurity = "ssl"
    smtp_username: str | None = None
    smtp_password: SecretStr | None = None
    smtp_password_file: str | None = None
    # "Name <address>" or a bare address; the envelope sender is the address part.
    smtp_from: str | None = None
    # A hung provider must not hold a request: mail is sent inline (failures are swallowed).
    smtp_timeout_seconds: float = Field(default=10.0, gt=0, le=60)

    @field_validator(
        "smtp_host",
        "smtp_port",
        "smtp_username",
        "smtp_password",
        "smtp_password_file",
        "smtp_from",
        mode="before",
    )
    @classmethod
    def _blank_smtp_is_unset(cls, value: object) -> object:
        return None if isinstance(value, str) and not value.strip() else value

    @field_validator("smtp_from")
    @classmethod
    def _sender_is_an_address(cls, value: str | None) -> str | None:
        if value is None:
            return None
        address = value.rpartition("<")[2].rstrip(">").strip() if "<" in value else value.strip()
        try:
            validate_email(address, check_deliverability=False)
        except EmailNotValidError:
            raise ValueError("SMTP_FROM must be an address or 'Name <address>'") from None
        return value

    @model_validator(mode="after")
    def _smtp_is_complete(self) -> Self:
        if self.email_backend != "smtp":
            return self
        if self.smtp_host is None:
            raise ValueError("SMTP_HOST is required when EMAIL_BACKEND=smtp")
        if self.smtp_from is None:
            raise ValueError("SMTP_FROM is required when EMAIL_BACKEND=smtp")
        has_password = self.smtp_password is not None or self.smtp_password_file is not None
        if self.smtp_username is not None and not has_password:
            raise ValueError("SMTP_PASSWORD (or SMTP_PASSWORD_FILE) is required with SMTP_USERNAME")
        if self.smtp_username is None and has_password:
            raise ValueError("SMTP_USERNAME is required with SMTP_PASSWORD")
        if self.smtp_port is None:
            self.smtp_port = DEFAULT_SMTP_PORTS[self.smtp_security]
        return self
