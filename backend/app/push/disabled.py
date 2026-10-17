"""The sender of a provider that is not configured: every delivery is dropped, visibly."""

from __future__ import annotations

from app.push.base import PushMessage, PushProvider, SendResult

PROVIDER_DISABLED = "provider_disabled"


class DisabledPushSender:
    def __init__(self, provider: PushProvider) -> None:
        self.provider = provider

    async def send(self, message: PushMessage) -> SendResult:
        return SendResult.fatal(PROVIDER_DISABLED)

    async def aclose(self) -> None:
        return None
