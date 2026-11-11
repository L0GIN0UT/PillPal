"""The work behind the 202 of the enumeration-sensitive auth endpoints, run after the response.

``register``, ``verify-email/resend`` and ``password-reset/request`` answer the same 202 for a
known and an unknown address. What made them differ was the work behind the answer: account
creation, a code row (cap count, lock, insert, commit) and a send for one case, nothing for the
other. So the request only validates, hashes the password (register) or looks the address up
(resend, reset), releases its database session and returns a :class:`MailJob`; the router runs it
with Starlette ``BackgroundTasks`` in a session of its own. For an unknown address the job carries
a random id, finds no account and ends there: both paths take the same steps in the request.

Why ``BackgroundTasks`` and not ARQ: the job needs no address or code in Redis, it works without a
worker (dev, e2e, the log sender), and it matches ``app.email_detached``, which already takes the
SMTP round-trip out of the request. The price is durability: a process that dies between the
response and the work loses the mail (or, for register, the account), and the user asks again.
The register payload (address, password hash, profile fields) lives in this process's memory only:
never in Redis, never in a log line, never in a ``repr``. Failures are logged as purpose and
exception class, never with an address or a code.

Equal timing assumes a server that runs background tasks after the final response body (uvicorn).

This module is a leaf (no service imports) so both the service and the runner can use it.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Literal, Protocol

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.email import EmailPurpose
from app.observability import get_logger

_log = get_logger("pillpal.auth")

MailKind = Literal["code", "known_address_notice", "register"]


@dataclass(frozen=True, repr=False)
class RegisterPayload:
    """Validated registration, held in memory until the job runs. No ``repr`` on purpose."""

    email: str
    password_hash: str
    locale: str
    timezone: str
    display_name: str | None
    consents: list[tuple[str, int]]
    device_id: str | None


@dataclass(frozen=True)
class MailJob:
    """``user_id`` is opaque; for an unknown address it is random and matches no account."""

    kind: MailKind
    user_id: uuid.UUID
    purpose: EmailPurpose | None = None
    register: RegisterPayload | None = field(default=None, repr=False)


def decoy_job(kind: MailKind, purpose: EmailPurpose | None = None) -> MailJob:
    return MailJob(kind=kind, user_id=uuid.uuid4(), purpose=purpose)


class MailDelivery(Protocol):
    async def deliver_mail(self, job: MailJob) -> None: ...


class MailRunner:
    """Runs jobs in their own session (the request's one is released before the job starts)."""

    def __init__(
        self,
        maker: async_sessionmaker[AsyncSession],
        delivery: Callable[[AsyncSession], MailDelivery],
    ) -> None:
        self._maker = maker
        self._delivery = delivery

    async def run(self, job: MailJob) -> None:
        try:
            async with self._maker() as session:
                await self._delivery(session).deliver_mail(job)
        except Exception as exc:
            _log.error(
                "auth_mail_job_failed", purpose=job.purpose or job.kind, exc_type=type(exc).__name__
            )
