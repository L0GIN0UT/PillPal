"""Outgoing e-mail: one-time codes and notices (account exists, deletion, restore).

Phase 1 has no real mail provider: :class:`LoggingEmailSender` is the default
outside production (it logs the account id and purpose - never the address -
and, only when explicitly enabled for local development, the code).
:class:`InMemoryEmailSender` is the test fake. Production refuses to start
with the logging sender (see ``app.main.create_app``).
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Literal, Protocol

from app.observability import get_logger

EmailPurpose = Literal["verify_email", "password_reset", "restore_account"]
# Notices carry no code and no capability: they tell the owner of the address what happened.
# ``deletion_requested``: "erased on X; if this wasn't you, restore and change your password".
# ``account_pending_deletion``: someone registered the address of a pending account.
NoticeKind = Literal[
    "account_exists", "deletion_requested", "account_restored", "account_pending_deletion"
]
EmailKind = Literal[
    "verify_email",
    "password_reset",
    "restore_account",
    "account_exists",
    "deletion_requested",
    "account_restored",
    "account_pending_deletion",
]

_log = get_logger("pillpal.email")


class EmailSender(Protocol):
    async def send_code(
        self, *, to: str, user_id: uuid.UUID, purpose: EmailPurpose, code: str
    ) -> None: ...

    async def send_account_exists(self, *, to: str, user_id: uuid.UUID) -> None:
        """Tell the owner of ``to`` that someone tried to register it again."""
        ...

    async def send_notice(
        self,
        *,
        to: str,
        user_id: uuid.UUID,
        kind: NoticeKind,
        erase_after: datetime | None = None,
    ) -> None:
        """A notice about the account; ``erase_after`` for the deletion notices."""
        ...


@dataclass(frozen=True)
class SentEmail:
    to: str
    user_id: uuid.UUID
    purpose: EmailKind
    code: str | None
    erase_after: datetime | None = None


@dataclass
class InMemoryEmailSender:
    outbox: list[SentEmail] = field(default_factory=list)

    async def send_code(
        self, *, to: str, user_id: uuid.UUID, purpose: EmailPurpose, code: str
    ) -> None:
        self.outbox.append(SentEmail(to=to, user_id=user_id, purpose=purpose, code=code))

    async def send_account_exists(self, *, to: str, user_id: uuid.UUID) -> None:
        self.outbox.append(SentEmail(to=to, user_id=user_id, purpose="account_exists", code=None))

    async def send_notice(
        self,
        *,
        to: str,
        user_id: uuid.UUID,
        kind: NoticeKind,
        erase_after: datetime | None = None,
    ) -> None:
        self.outbox.append(
            SentEmail(to=to, user_id=user_id, purpose=kind, code=None, erase_after=erase_after)
        )


class LoggingEmailSender:
    """Development stand-in for a mail provider; drops the mail and logs an event."""

    def __init__(self, *, log_codes: bool = False) -> None:
        self._log_codes = log_codes

    async def send_code(
        self, *, to: str, user_id: uuid.UUID, purpose: EmailPurpose, code: str
    ) -> None:
        extra = {"dev_code": code} if self._log_codes else {}
        _log.info("email_code_sent", user_id=str(user_id), purpose=purpose, **extra)

    async def send_account_exists(self, *, to: str, user_id: uuid.UUID) -> None:
        _log.info("email_notice_sent", user_id=str(user_id), purpose="account_exists")

    async def send_notice(
        self,
        *,
        to: str,
        user_id: uuid.UUID,
        kind: NoticeKind,
        erase_after: datetime | None = None,
    ) -> None:
        _log.info("email_notice_sent", user_id=str(user_id), purpose=kind)
