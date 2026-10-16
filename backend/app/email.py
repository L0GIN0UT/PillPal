"""Outgoing e-mail with one-time codes.

Phase 1 has no real mail provider: :class:`LoggingEmailSender` is the default
(logs a masked address and, only when explicitly enabled for local
development, the code). :class:`InMemoryEmailSender` is the test fake.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, Protocol

from app.observability import get_logger

EmailPurpose = Literal["verify_email", "password_reset"]

_log = get_logger("pillpal.email")


def mask_email(email: str) -> str:
    local, _, domain = email.partition("@")
    return f"{local[:1]}***@{domain}" if domain else "***"


class EmailSender(Protocol):
    async def send_code(self, *, to: str, purpose: EmailPurpose, code: str) -> None: ...


@dataclass(frozen=True)
class SentEmail:
    to: str
    purpose: EmailPurpose
    code: str


@dataclass
class InMemoryEmailSender:
    outbox: list[SentEmail] = field(default_factory=list)

    async def send_code(self, *, to: str, purpose: EmailPurpose, code: str) -> None:
        self.outbox.append(SentEmail(to=to, purpose=purpose, code=code))


class LoggingEmailSender:
    def __init__(self, *, log_codes: bool = False) -> None:
        self._log_codes = log_codes

    async def send_code(self, *, to: str, purpose: EmailPurpose, code: str) -> None:
        extra = {"dev_code": code} if self._log_codes else {}
        _log.info("email_code_sent", to=mask_email(to), purpose=purpose, **extra)
