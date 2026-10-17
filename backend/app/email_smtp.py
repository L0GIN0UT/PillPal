"""Real e-mail over SMTP (implicit TLS on 465 or STARTTLS on 587), async via ``aiosmtplib``.

Failures raise :class:`EmailDeliveryError` with only the exception class name: the original
exception can carry the server's reply or the address, so it is not chained (``from None``).
Callers (``AuthService``) already treat a send failure as "the user can ask for a new code",
so a mail outage never changes an HTTP response (no account enumeration by timing or status).
"""

from __future__ import annotations

import ssl
import uuid
from datetime import datetime
from email.message import EmailMessage
from email.utils import formatdate, make_msgid, parseaddr
from typing import Literal

import aiosmtplib

from app.config import Settings
from app.email import EmailDeliveryError, EmailKind, EmailPurpose, NoticeKind
from app.email_templates import render
from app.observability import get_logger

_log = get_logger("pillpal.email.smtp")


class SmtpEmailSender:
    def __init__(
        self,
        *,
        host: str,
        port: int,
        security: Literal["ssl", "starttls"],
        username: str | None,
        password: str | None,
        sender: str,
        timeout_seconds: float,
        code_ttl_minutes: int,
        tls_context: ssl.SSLContext | None = None,
    ) -> None:
        self._host = host
        self._port = port
        self._security = security
        self._username = username
        self._password = password
        self._sender = sender
        self._envelope_sender = parseaddr(sender)[1]
        self._timeout = timeout_seconds
        self._ttl_minutes = code_ttl_minutes
        # Default: the system trust store with host name checking. Tests inject their own CA.
        self._tls_context = tls_context or ssl.create_default_context()

    async def send_code(
        self, *, to: str, user_id: uuid.UUID, purpose: EmailPurpose, code: str
    ) -> None:
        await self._send(to, purpose, code=code)

    async def send_account_exists(self, *, to: str, user_id: uuid.UUID) -> None:
        await self._send(to, "account_exists")

    async def send_notice(
        self,
        *,
        to: str,
        user_id: uuid.UUID,
        kind: NoticeKind,
        erase_after: datetime | None = None,
    ) -> None:
        await self._send(to, kind, erase_after=erase_after)

    async def _send(
        self,
        to: str,
        kind: EmailKind,
        *,
        code: str | None = None,
        erase_after: datetime | None = None,
    ) -> None:
        subject, body = render(
            kind, code=code, ttl_minutes=self._ttl_minutes, erase_after=erase_after
        )
        message = EmailMessage()
        message["From"] = self._sender
        message["To"] = to
        message["Subject"] = subject
        message["Date"] = formatdate(localtime=False)
        message["Message-ID"] = make_msgid(domain=self._envelope_sender.rpartition("@")[2])
        message["Auto-Submitted"] = "auto-generated"
        message.set_content(body)
        try:
            await aiosmtplib.send(
                message,
                sender=self._envelope_sender,
                recipients=[to],
                hostname=self._host,
                port=self._port,
                use_tls=self._security == "ssl",
                start_tls=self._security == "starttls",
                username=self._username,
                password=self._password,
                timeout=self._timeout,
                tls_context=self._tls_context,
            )
        except Exception as exc:
            # The class name is the diagnosis (auth, connect, timeout); the message may hold the
            # address or the server's reply, so it is neither logged nor chained.
            reason = type(exc).__name__
            _log.error("smtp_send_failed", kind=kind, reason=reason)
            raise EmailDeliveryError(f"smtp send failed: {reason}") from None


def smtp_sender_from_settings(settings: Settings) -> SmtpEmailSender:
    if settings.smtp_host is None or settings.smtp_from is None or settings.smtp_port is None:
        raise RuntimeError("EMAIL_BACKEND=smtp needs SMTP_HOST and SMTP_FROM")  # validator bypassed
    password = settings.smtp_password.get_secret_value() if settings.smtp_password else None
    return SmtpEmailSender(
        host=settings.smtp_host,
        port=settings.smtp_port,
        security=settings.smtp_security,
        username=settings.smtp_username,
        password=password,
        sender=settings.smtp_from,
        timeout_seconds=settings.smtp_timeout_seconds,
        code_ttl_minutes=max(1, settings.email_code_ttl_seconds // 60),
    )
