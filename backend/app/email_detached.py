"""Sends mail off the request path.

With a real provider a send takes hundreds of milliseconds (or the whole timeout when the provider
hangs), and only the requests that mail something would pay it: "register" for an address that has
an account mails a notice, for an unknown one a code - the same 202, but a different latency. That
is an account-enumeration oracle, so the request never waits for the provider.

Plain ``asyncio`` tasks, not the ARQ queue: the address and the code must not be written to Redis.
The tasks live in this process only (a restart loses an unsent mail; the user asks for a new code).
Failures are logged as kind and exception class, never with the address or the code.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import Coroutine
from datetime import datetime
from typing import Any

from app.email import EmailKind, EmailPurpose, EmailSender, NoticeKind
from app.observability import get_logger

_log = get_logger("pillpal.email")


class DetachedEmailSender:
    def __init__(self, inner: EmailSender, *, drain_timeout_seconds: float = 15.0) -> None:
        self._inner = inner
        self._drain_timeout = drain_timeout_seconds
        # A task with no reference can be garbage-collected mid-flight.
        self._tasks: set[asyncio.Task[None]] = set()

    async def send_code(
        self, *, to: str, user_id: uuid.UUID, purpose: EmailPurpose, code: str
    ) -> None:
        self._spawn(
            purpose, self._inner.send_code(to=to, user_id=user_id, purpose=purpose, code=code)
        )

    async def send_account_exists(self, *, to: str, user_id: uuid.UUID) -> None:
        self._spawn("account_exists", self._inner.send_account_exists(to=to, user_id=user_id))

    async def send_notice(
        self,
        *,
        to: str,
        user_id: uuid.UUID,
        kind: NoticeKind,
        erase_after: datetime | None = None,
    ) -> None:
        self._spawn(
            kind,
            self._inner.send_notice(to=to, user_id=user_id, kind=kind, erase_after=erase_after),
        )

    def _spawn(self, kind: EmailKind, send: Coroutine[Any, Any, None]) -> None:
        task = asyncio.get_running_loop().create_task(self._run(kind, send))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    @staticmethod
    async def _run(kind: EmailKind, send: Coroutine[Any, Any, None]) -> None:
        try:
            await send
        except Exception as exc:
            _log.error("email_send_failed", purpose=kind, exc_type=type(exc).__name__)

    async def drain(self) -> None:
        """Wait for the mails in flight (shutdown); a hung provider is cut off after the timeout."""
        pending = set(self._tasks)
        if not pending:
            return
        _, still_running = await asyncio.wait(pending, timeout=self._drain_timeout)
        for task in still_running:
            task.cancel()
        if still_running:
            await asyncio.gather(*still_running, return_exceptions=True)
