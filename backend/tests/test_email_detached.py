"""Mail leaves the request path: a slow or hung provider must not make known addresses
distinguishable from unknown ones by response time (account enumeration)."""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import datetime

import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from app.email import EmailPurpose, InMemoryEmailSender, NoticeKind
from app.email_detached import DetachedEmailSender
from app.main import create_app
from tests.conftest import make_settings
from tests.helpers import DEFAULT_PASSWORD, register


class GatedSender(InMemoryEmailSender):
    """Every send waits for ``gate``, like a provider that hangs until its timeout."""

    def __init__(self, *, fail: bool = False) -> None:
        super().__init__()
        self.gate = asyncio.Event()
        self.fail = fail

    async def _wait(self) -> None:
        await self.gate.wait()
        if self.fail:
            raise RuntimeError("provider down")

    async def send_code(
        self, *, to: str, user_id: uuid.UUID, purpose: EmailPurpose, code: str
    ) -> None:
        await self._wait()
        await super().send_code(to=to, user_id=user_id, purpose=purpose, code=code)

    async def send_account_exists(self, *, to: str, user_id: uuid.UUID) -> None:
        await self._wait()
        await super().send_account_exists(to=to, user_id=user_id)

    async def send_notice(
        self,
        *,
        to: str,
        user_id: uuid.UUID,
        kind: NoticeKind,
        erase_after: datetime | None = None,
    ) -> None:
        await self._wait()
        await super().send_notice(to=to, user_id=user_id, kind=kind, erase_after=erase_after)


@pytest_asyncio.fixture
async def detached(
    client: AsyncClient,
) -> AsyncIterator[tuple[AsyncClient, GatedSender, DetachedEmailSender]]:
    inner = GatedSender()
    sender = DetachedEmailSender(inner)
    app = create_app(make_settings(), email_sender=sender)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as api:
            yield api, inner, sender


async def _register(api: AsyncClient, email: str) -> object:
    resp = await api.post(
        "/v1/auth/register",
        json={
            "email": email,
            "password": DEFAULT_PASSWORD,
            "region": "ru",
            "timezone": "Europe/Samara",
        },
    )
    return resp.status_code, resp.json()


async def test_responses_do_not_wait_for_the_provider_and_do_not_differ(
    client: AsyncClient,
    detached: tuple[AsyncClient, GatedSender, DetachedEmailSender],
) -> None:
    api, inner, sender = detached
    known = (await register(client)).email
    unknown = f"new-{uuid.uuid4().hex[:8]}@example.com"

    answers = await asyncio.wait_for(
        asyncio.gather(_register(api, known), _register(api, unknown)), timeout=10
    )

    assert answers[0] == answers[1] == (202, {"status": "verification_sent"})
    assert inner.outbox == []  # the gate is still closed: nothing was awaited inline
    inner.gate.set()
    await sender.drain()
    assert sorted(m.purpose for m in inner.outbox) == ["account_exists", "verify_email"]


async def test_a_failing_provider_is_swallowed_and_drain_still_finishes() -> None:
    inner = GatedSender(fail=True)
    sender = DetachedEmailSender(inner)
    await sender.send_code(
        to="a@example.org", user_id=uuid.uuid4(), purpose="verify_email", code="123456"
    )
    inner.gate.set()
    await sender.drain()  # no exception, no pending task left
    assert inner.outbox == []


async def test_drain_is_bounded_when_the_provider_hangs() -> None:
    inner = GatedSender()  # the gate never opens
    sender = DetachedEmailSender(inner, drain_timeout_seconds=0.2)
    await sender.send_account_exists(to="a@example.org", user_id=uuid.uuid4())
    await asyncio.wait_for(sender.drain(), timeout=5)


def test_only_the_smtp_backend_is_detached() -> None:
    from app.email import InMemoryEmailSender
    from tests.test_email_config import smtp_settings

    assert isinstance(
        create_app(smtp_settings(environment="staging")).state.email_sender, DetachedEmailSender
    )
    memory = create_app(make_settings(email_backend="memory")).state.email_sender
    assert isinstance(memory, InMemoryEmailSender)
