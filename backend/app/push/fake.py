"""An in-memory sender for tests and local development (no network, no credentials)."""

from __future__ import annotations

import asyncio
from collections.abc import Callable

from app.push.base import PushMessage, PushProvider, SendResult


class FakePushSender:
    """Records messages; answers from ``results`` (consumed in order) or ``respond``, else OK."""

    def __init__(
        self,
        provider: PushProvider,
        respond: Callable[[PushMessage], SendResult] | None = None,
    ) -> None:
        self.provider = provider
        self.sent: list[PushMessage] = []
        self.results: list[SendResult] = []
        self.respond = respond
        # Set to hold sends open, to observe concurrency.
        self.gate: asyncio.Event | None = None
        self.in_flight = 0
        self.max_in_flight = 0

    ok = staticmethod(SendResult.ok)
    retry = staticmethod(SendResult.retry)
    fatal = staticmethod(SendResult.fatal)
    invalid_token = staticmethod(SendResult.invalid_token)

    async def send(self, message: PushMessage) -> SendResult:
        self.in_flight += 1
        self.max_in_flight = max(self.max_in_flight, self.in_flight)
        try:
            await asyncio.sleep(0)
            if self.gate is not None:
                await self.gate.wait()
            self.sent.append(message)
            if self.results:
                return self.results.pop(0)
            if self.respond is not None:
                return self.respond(message)
            return SendResult.ok()
        finally:
            self.in_flight -= 1

    async def aclose(self) -> None:
        return None
