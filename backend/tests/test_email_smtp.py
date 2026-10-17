"""SmtpEmailSender against a real in-process SMTP server (TLS, STARTTLS, auth, failures)."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime
from typing import Literal

import pytest

from app.email import EmailDeliveryError, EmailPurpose, NoticeKind
from app.email_smtp import SmtpEmailSender
from tests.smtp_helpers import LOOPBACK, PASSWORD, USERNAME, FakeSmtp, fake_smtp, free_port

USER_ID = uuid.uuid4()
SENDER = "PillPal <noreply@pillpal.example>"
Security = Literal["ssl", "starttls"]


def sender_for(
    fake: FakeSmtp, security: Security, *, password: str = PASSWORD, timeout: float = 5.0
) -> SmtpEmailSender:
    return SmtpEmailSender(
        host=LOOPBACK,
        port=fake.port,
        security=security,
        username=USERNAME,
        password=password,
        sender=SENDER,
        timeout_seconds=timeout,
        code_ttl_minutes=15,
        tls_context=fake.client_context(),
    )


@pytest.mark.parametrize("security", ["ssl", "starttls"])
async def test_code_mail_is_delivered_with_login_over_tls(security: Security) -> None:
    with fake_smtp(security=security) as fake:
        await sender_for(fake, security).send_code(
            to="rita@example.org", user_id=USER_ID, purpose="verify_email", code="482913"
        )
    assert fake.logins == [(USERNAME, PASSWORD)]
    (mail,) = fake.delivered
    assert mail.envelope_to == ["rita@example.org"]
    assert mail.envelope_from == "noreply@pillpal.example"
    assert mail.message["From"] == SENDER
    assert "482913" in mail.text
    assert "482913" not in str(mail.message["Subject"])


async def test_every_purpose_and_notice_is_sent() -> None:
    purposes: list[EmailPurpose] = ["verify_email", "password_reset", "restore_account"]
    kinds: list[NoticeKind] = [
        "deletion_requested",
        "account_restored",
        "account_pending_deletion",
    ]
    when = datetime(2026, 11, 16, 8, 30, tzinfo=UTC)
    with fake_smtp(security="ssl") as fake:
        sender = sender_for(fake, "ssl")
        for purpose in purposes:
            await sender.send_code(
                to="a@example.org", user_id=USER_ID, purpose=purpose, code="111222"
            )
        await sender.send_account_exists(to="a@example.org", user_id=USER_ID)
        for kind in kinds:
            await sender.send_notice(
                to="a@example.org", user_id=USER_ID, kind=kind, erase_after=when
            )
    assert len(fake.delivered) == len(purposes) + 1 + len(kinds)
    assert len({str(m.message["Subject"]) for m in fake.delivered}) == len(fake.delivered)


async def test_cyrillic_body_survives_the_wire() -> None:
    with fake_smtp(security="ssl") as fake:
        await sender_for(fake, "ssl").send_account_exists(to="a@example.org", user_id=USER_ID)
    assert "аккаунт" in fake.delivered[0].text


async def test_wrong_password_raises_without_leaking_it() -> None:
    with fake_smtp(security="ssl") as fake, pytest.raises(EmailDeliveryError) as caught:
        await sender_for(fake, "ssl", password="wrong-pass").send_code(
            to="rita@example.org", user_id=USER_ID, purpose="verify_email", code="482913"
        )
    assert fake.delivered == []
    text = repr(caught.value) + str(caught.value.__cause__) + str(caught.value.__context__)
    for secret in ("wrong-pass", "rita@example.org", "482913"):
        assert secret not in text


async def test_unreachable_server_raises_delivery_error() -> None:
    sender = SmtpEmailSender(
        host=LOOPBACK,
        port=free_port(),
        security="ssl",
        username=None,
        password=None,
        sender=SENDER,
        timeout_seconds=2.0,
        code_ttl_minutes=15,
    )
    with pytest.raises(EmailDeliveryError):
        await sender.send_account_exists(to="a@example.org", user_id=USER_ID)


async def test_silent_server_hits_the_timeout() -> None:
    async def silent(_r: asyncio.StreamReader, _w: asyncio.StreamWriter) -> None:
        await asyncio.sleep(30)

    server = await asyncio.start_server(silent, LOOPBACK, 0)
    port = server.sockets[0].getsockname()[1]
    sender = SmtpEmailSender(
        host=LOOPBACK,
        port=port,
        security="starttls",
        username=None,
        password=None,
        sender=SENDER,
        timeout_seconds=0.3,
        code_ttl_minutes=15,
    )
    try:
        with pytest.raises(EmailDeliveryError):
            await asyncio.wait_for(
                sender.send_account_exists(to="a@example.org", user_id=USER_ID), timeout=5
            )
    finally:
        server.close()


async def test_starttls_is_never_downgraded_to_plain_text() -> None:
    with fake_smtp(security="plain") as fake, pytest.raises(EmailDeliveryError):
        await sender_for(fake, "starttls").send_code(
            to="rita@example.org", user_id=USER_ID, purpose="verify_email", code="482913"
        )
    assert fake.delivered == []
    assert fake.logins == []
