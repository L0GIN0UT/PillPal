"""The mail step of the enumeration-sensitive auth endpoints, run after the response.

``register``, ``verify-email/resend`` and ``password-reset/request`` answer the same 202 for a
known and an unknown address. What made them differ was the work behind the answer: for a known
address a code row (cap count, lock, insert, commit) and a send, for an unknown one nothing. So
the request does one thing only, a lookup, and returns a :class:`MailJob`; the router runs it with
Starlette ``BackgroundTasks``. An unknown address yields a job with a random id that finds no
account and ends there: both paths take the same steps in the request.

Why ``BackgroundTasks`` and not ARQ: the job needs no address and no code in Redis (it carries an
opaque account id, the code is generated and mailed in the same process), it works without a worker
(dev, e2e, the log sender), and it matches ``app.email_detached``, which already takes the SMTP
round-trip out of the request. The price is durability: a process that dies between the response
and the send loses the mail, and the user asks for a new code (the caps and the response are
unchanged). Failures are logged as purpose and exception class, never with an address or a code.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Literal

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings
from app.email import EmailPurpose, EmailSender
from app.observability import get_logger
from app.security import PasswordHasher, TokenService

_log = get_logger("pillpal.auth")

MailKind = Literal["code", "known_address_notice"]


@dataclass(frozen=True)
class MailJob:
    """``user_id`` is opaque; for an unknown address it is random and matches no account."""

    kind: MailKind
    user_id: uuid.UUID
    purpose: EmailPurpose | None = None


def decoy_job(kind: MailKind, purpose: EmailPurpose | None = None) -> MailJob:
    return MailJob(kind=kind, user_id=uuid.uuid4(), purpose=purpose)


class MailRunner:
    """Runs jobs in their own session (the request's one is closed by then)."""

    def __init__(
        self,
        maker: async_sessionmaker[AsyncSession],
        settings: Settings,
        tokens: TokenService,
        hasher: PasswordHasher,
        email_sender: EmailSender,
        redis: Redis,
    ) -> None:
        self._maker = maker
        self._settings = settings
        self._tokens = tokens
        self._hasher = hasher
        self._email_sender = email_sender
        self._redis = redis

    async def run(self, job: MailJob) -> None:
        from app.services.auth import AuthService  # AuthService imports MailJob

        try:
            async with self._maker() as session:
                service = AuthService(
                    session,
                    self._settings,
                    self._tokens,
                    self._hasher,
                    self._email_sender,
                    self._redis,
                )
                await service.deliver_mail(job)
        except Exception as exc:
            _log.error(
                "auth_mail_job_failed", purpose=job.purpose or job.kind, exc_type=type(exc).__name__
            )
