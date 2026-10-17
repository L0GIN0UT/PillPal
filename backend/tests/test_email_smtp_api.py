"""Account flows end to end with real SMTP delivery (real PostgreSQL + Redis behind the API)."""

from __future__ import annotations

import re
from collections.abc import AsyncIterator

import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from app.email_smtp import SmtpEmailSender
from app.main import create_app
from tests.conftest import make_settings
from tests.helpers import DEFAULT_PASSWORD, register_unverified
from tests.smtp_helpers import LOOPBACK, PASSWORD, USERNAME, FakeSmtp, fake_smtp, free_port

SENDER = "PillPal <noreply@pillpal.example>"


def _sender(port: int, fake: FakeSmtp | None) -> SmtpEmailSender:
    return SmtpEmailSender(
        host=LOOPBACK,
        port=port,
        security="ssl",
        username=USERNAME,
        password=PASSWORD,
        sender=SENDER,
        timeout_seconds=2.0,
        code_ttl_minutes=15,
        tls_context=fake.client_context() if fake else None,
    )


async def _client_with(sender: SmtpEmailSender) -> AsyncIterator[AsyncClient]:
    app = create_app(make_settings(), email_sender=sender)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


@pytest_asyncio.fixture
async def smtp_client(clean_state: None) -> AsyncIterator[tuple[AsyncClient, FakeSmtp]]:
    with fake_smtp(security="ssl") as fake:
        async for client in _client_with(_sender(fake.port, fake)):
            yield client, fake


async def test_verification_code_arrives_by_smtp_and_verifies(
    smtp_client: tuple[AsyncClient, FakeSmtp],
) -> None:
    client, fake = smtp_client
    email = await register_unverified(client)
    (mail,) = fake.delivered
    assert mail.envelope_to == [email]
    match = re.search(r"\b(\d{6})\b", mail.text)
    assert match is not None
    verified = await client.post(
        "/v1/auth/verify-email", json={"email": email, "code": match.group(1)}
    )
    assert verified.status_code == 200
    login = await client.post("/v1/auth/login", json={"email": email, "password": DEFAULT_PASSWORD})
    assert login.status_code == 200


async def test_registering_an_existing_address_mails_a_notice_without_a_code(
    smtp_client: tuple[AsyncClient, FakeSmtp],
) -> None:
    client, fake = smtp_client
    email = await register_unverified(client)
    first = fake.delivered[0]
    code = re.search(r"\b(\d{6})\b", first.text)
    assert code is not None
    await client.post("/v1/auth/verify-email", json={"email": email, "code": code.group(1)})
    again = await client.post(
        "/v1/auth/register",
        json={
            "email": email,
            "password": DEFAULT_PASSWORD,
            "region": "ru",
            "timezone": "Europe/Samara",
        },
    )
    assert again.status_code == 202
    assert again.json() == {"status": "verification_sent"}
    assert len(fake.delivered) == 2
    assert re.search(r"\d{6}", fake.delivered[1].text) is None


async def test_smtp_outage_does_not_change_the_response(clean_state: None) -> None:
    # Nothing listens on the port: the user sees the same 202 as with a working provider
    # (no enumeration, no 5xx) and can ask for a new code later.
    async for client in _client_with(_sender(free_port(), None)):
        await register_unverified(client)
