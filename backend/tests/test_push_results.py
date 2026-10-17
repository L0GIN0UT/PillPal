"""How ``deliver_pending`` records what a provider answered: retry back-off, dead tokens and
fatal errors (ADR 0008 §6)."""

from __future__ import annotations

import uuid
from datetime import timedelta

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.push.base import SendResult
from tests.conftest import FakeClock
from tests.helpers import register
from tests.push_helpers import APNS_TOKEN, fcm_token, put_token, rows
from tests.push_outbox_helpers import (
    deliver,
    fake_senders,
    insert_outbox,
    outbox_rows,
    queued_for_new_user,
)


async def test_retry_backs_off_30s_2min_10min_30min_then_drops(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await queued_for_new_user(client, engine)
    senders = fake_senders()
    senders["fcm"].respond = lambda message: SendResult.retry("UNAVAILABLE")
    for attempt, delay in enumerate((30, 120, 600, 1800), start=1):
        report = await deliver(maker, settings, senders, now)
        assert report.retried == 1
        (row,) = await outbox_rows(engine)
        assert (row.status, row.attempts, row.last_error_code) == (
            "pending",
            attempt,
            "UNAVAILABLE",
        )
        due = row.next_attempt_at
        assert due == now() + timedelta(seconds=delay)
        # Not claimed one second early.
        now.now = due - timedelta(seconds=1)
        assert (await deliver(maker, settings, senders, now)).retried == 0
        now.now = due
    report = await deliver(maker, settings, senders, now)  # the fifth and last attempt
    assert report.dropped == 1
    (row,) = await outbox_rows(engine)
    assert (row.status, row.attempts, row.last_error_code) == ("dropped", 5, "UNAVAILABLE")
    assert len(senders["fcm"].sent) == 5


async def test_retry_after_longer_than_the_backoff_wins_and_is_capped(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await queued_for_new_user(client, engine)
    senders = fake_senders()
    senders["fcm"].results = [SendResult.retry("QUOTA_EXCEEDED", 300.0)]
    await deliver(maker, settings, senders, now)
    (row,) = await outbox_rows(engine)
    assert row.next_attempt_at == now() + timedelta(seconds=300)  # the back-off alone is 30 s
    now.now = row.next_attempt_at
    senders["fcm"].results = [SendResult.retry("QUOTA_EXCEEDED", 10 * 24 * 3600.0)]
    await deliver(maker, settings, senders, now)
    (row,) = await outbox_rows(engine)
    assert row.next_attempt_at == now() + timedelta(seconds=settings.push_stale_after_seconds)


async def test_a_short_retry_after_never_undercuts_the_backoff(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await queued_for_new_user(client, engine)
    senders = fake_senders()
    senders["fcm"].results = [SendResult.retry("QUOTA_EXCEEDED", 5.0)]
    await deliver(maker, settings, senders, now)
    (row,) = await outbox_rows(engine)
    assert row.next_attempt_at == now() + timedelta(seconds=30)


async def test_invalid_token_deletes_the_token_and_its_pending_rows(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    bystander = await register(client)
    await put_token(client, bystander, "other-dev")
    await insert_outbox(engine, bystander, bystander.self_profile_id)
    user, _ = await queued_for_new_user(client, engine, n=3)
    senders = fake_senders()
    dead = fcm_token("dev-1")
    senders["fcm"].respond = lambda m: (
        SendResult.invalid_token("UNREGISTERED") if m.token == dead else SendResult.ok()
    )
    report = await deliver(maker, settings, senders, now)
    assert (report.sent, report.invalid_tokens) == (1, 1)  # one token deleted for three messages
    left = await rows(engine, "SELECT user_id FROM push_tokens")
    assert [r.user_id for r in left] == [uuid.UUID(bystander.id)]
    remaining = await outbox_rows(engine)
    assert [(r.recipient_user_id, r.status) for r in remaining] == [
        (uuid.UUID(bystander.id), "sent")
    ]
    assert user.id


async def test_an_invalid_token_is_deleted_unless_it_was_registered_after_the_provider_said(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    user = await register(client)
    await put_token(client, user, provider="apns", token=APNS_TOKEN, apns_environment="production")
    await insert_outbox(engine, user, user.self_profile_id)
    senders = fake_senders()
    registered = (await rows(engine, "SELECT updated_at FROM push_tokens"))[0].updated_at
    # APNs 410: invalid since before the app re-registered it: keep the token, retry the row.
    senders["apns"].results = [
        SendResult.invalid_token("Unregistered", registered - timedelta(hours=1))
    ]
    report = await deliver(maker, settings, senders, now)
    assert report.invalid_tokens == 0
    assert len(await rows(engine, "SELECT 1 FROM push_tokens")) == 1
    (row,) = await outbox_rows(engine)
    assert (row.status, row.last_error_code) == ("pending", "Unregistered")
    # Invalid since after the registration: gone, with the pending row.
    now.advance(hours=1)
    senders["apns"].results = [
        SendResult.invalid_token("Unregistered", registered + timedelta(hours=1))
    ]
    await deliver(maker, settings, senders, now)
    assert await rows(engine, "SELECT 1 FROM push_tokens") == []
    assert await outbox_rows(engine) == []


async def test_fatal_drops_the_row_with_the_provider_code(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await queued_for_new_user(client, engine)
    senders = fake_senders()
    senders["fcm"].results = [SendResult.fatal("SENDER_ID_MISMATCH")]
    report = await deliver(maker, settings, senders, now)
    assert report.dropped == 1
    (row,) = await outbox_rows(engine)
    assert (row.status, row.last_error_code) == ("dropped", "SENDER_ID_MISMATCH")
    assert len(await rows(engine, "SELECT 1 FROM push_tokens")) == 1  # config error, token kept
