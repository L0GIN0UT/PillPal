"""``deliver_pending``: claim, send, record (ADR 0008 §6)."""

from __future__ import annotations

import asyncio
from datetime import timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.push.base import SendResult
from app.push.disabled import DisabledPushSender
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


async def test_ok_marks_the_row_sent_and_the_token_successful(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    user, (row_id,) = await queued_for_new_user(client, engine)
    senders = fake_senders()
    report = await deliver(maker, settings, senders, now)
    assert (report.sent, report.dropped, report.retried) == (1, 0, 0)
    (row,) = await outbox_rows(engine)
    assert (row.status, row.attempts, row.last_error_code) == ("sent", 1, None)
    assert row.sent_at is not None
    (message,) = senders["fcm"].sent
    assert message.token == fcm_token("dev-1")
    assert message.delivery_id == str(row_id)
    assert message.payload.to_wire() == row.payload
    assert message.ttl_seconds == settings.push_stale_after_seconds
    assert message.apns_environment is None
    (token,) = await rows(engine, "SELECT last_success_at FROM push_tokens")
    assert token.last_success_at is not None
    # Delivered once: the next run finds nothing.
    assert (await deliver(maker, settings, senders, now)).sent == 0
    assert len(senders["fcm"].sent) == 1
    assert user.id


async def test_each_provider_gets_its_own_sender_and_apns_environment(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    user = await register(client)
    await put_token(
        client, user, "ios", provider="apns", token=APNS_TOKEN, apns_environment="sandbox"
    )
    await put_token(client, user, "huawei", provider="rustore", token="rs-token")
    await insert_outbox(engine, user, user.self_profile_id, device="ios")
    await insert_outbox(engine, user, user.self_profile_id, device="huawei")
    senders = fake_senders()
    assert (await deliver(maker, settings, senders, now)).sent == 2
    assert [m.token for m in senders["apns"].sent] == [APNS_TOKEN]
    assert senders["apns"].sent[0].apns_environment == "sandbox"
    assert [m.token for m in senders["rustore"].sent] == ["rs-token"]
    assert senders["fcm"].sent == []


async def test_rows_that_are_not_due_are_left_alone(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    user = await register(client)
    await put_token(client, user)
    await insert_outbox(
        engine, user, user.self_profile_id, next_attempt_at=now() + timedelta(minutes=5)
    )
    senders = fake_senders()
    assert (await deliver(maker, settings, senders, now)).sent == 0
    now.advance(minutes=5, seconds=1)
    assert (await deliver(maker, settings, senders, now)).sent == 1


async def test_stale_rows_are_dropped_without_sending(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    user = await register(client)
    await put_token(client, user)
    await insert_outbox(
        engine,
        user,
        user.self_profile_id,
        created_at=now() - timedelta(seconds=settings.push_stale_after_seconds + 1),
    )
    await insert_outbox(
        engine,
        user,
        user.self_profile_id,
        created_at=now() - timedelta(seconds=settings.push_stale_after_seconds - 60),
    )
    senders = fake_senders()
    report = await deliver(maker, settings, senders, now)
    assert (report.sent, report.dropped) == (1, 1)
    first, second = await outbox_rows(engine)
    assert (first.status, first.last_error_code) == ("dropped", "stale")
    assert second.status == "sent"
    assert len(senders["fcm"].sent) == 1


async def test_rows_that_exhausted_their_attempts_are_dropped_even_after_a_crash(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    user = await register(client)
    await put_token(client, user)
    await insert_outbox(engine, user, user.self_profile_id, attempts=settings.push_max_attempts)
    senders = fake_senders()
    assert (await deliver(maker, settings, senders, now)).dropped == 1
    (row,) = await outbox_rows(engine)
    assert (row.status, row.last_error_code) == ("dropped", "max_attempts")
    assert senders["fcm"].sent == []


async def test_a_disabled_provider_drops_with_provider_disabled(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await queued_for_new_user(client, engine)
    senders = fake_senders()
    senders["fcm"] = DisabledPushSender("fcm")  # type: ignore[assignment]
    report = await deliver(maker, settings, senders, now)
    assert report.dropped == 1
    (row,) = await outbox_rows(engine)
    assert (row.status, row.last_error_code) == ("dropped", "provider_disabled")


async def test_a_sender_that_raises_is_retried_not_fatal(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await queued_for_new_user(client, engine, n=2)

    def explode(message: object) -> SendResult:
        raise RuntimeError("boom with secret tokenvalue")

    senders = fake_senders()
    senders["fcm"].respond = explode
    report = await deliver(maker, settings, senders, now)
    assert report.retried == 2
    assert {r.last_error_code for r in await outbox_rows(engine)} == {"sender_error"}


async def test_two_concurrent_claimers_never_send_a_row_twice(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(settings, "push_batch_size", 7)
    await queued_for_new_user(client, engine, n=60)
    senders = fake_senders()
    reports = await asyncio.gather(*[deliver(maker, settings, senders, now) for _ in range(3)])
    delivered = [m.delivery_id for m in senders["fcm"].sent]
    assert len(delivered) == 60
    assert len(set(delivered)) == 60
    assert sum(r.sent for r in reports) == 60
    assert {r.status for r in await outbox_rows(engine)} == {"sent"}


async def test_a_claimed_row_is_not_resent_until_its_lease_runs_out(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    from app.services.push_delivery import claim_batch

    await queued_for_new_user(client, engine)
    async with maker() as session:
        claim = await claim_batch(session, settings, now())  # the worker dies after this
    assert len(claim.items) == 1
    senders = fake_senders()
    assert (await deliver(maker, settings, senders, now)).sent == 0
    now.advance(seconds=settings.push_claim_lease_seconds + 1)
    assert (await deliver(maker, settings, senders, now)).sent == 1
    (row,) = await outbox_rows(engine)
    assert row.attempts == 2  # the lost attempt counts, so a poison row cannot loop forever


async def test_sends_run_concurrently_up_to_the_configured_bound(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(settings, "push_send_concurrency", 3)
    await queued_for_new_user(client, engine, n=10)
    senders = fake_senders()
    senders["fcm"].gate = asyncio.Event()
    task = asyncio.create_task(deliver(maker, settings, senders, now))
    for _ in range(200):
        if senders["fcm"].in_flight == 3:
            break
        await asyncio.sleep(0.01)
    assert senders["fcm"].in_flight == 3
    senders["fcm"].gate.set()
    report = await task
    assert report.sent == 10
    assert senders["fcm"].max_in_flight == 3


async def test_a_backlog_is_worked_off_in_batches_within_one_run(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(settings, "push_batch_size", 4)
    monkeypatch.setattr(settings, "push_max_batches_per_run", 2)
    await queued_for_new_user(client, engine, n=10)
    senders = fake_senders()
    assert (await deliver(maker, settings, senders, now)).sent == 8  # two batches of four
    assert (await deliver(maker, settings, senders, now)).sent == 2


async def test_staleness_follows_the_injected_clock(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await queued_for_new_user(client, engine)
    now.advance(days=3)  # far past the real "now": the row is stale for this clock
    senders = fake_senders()
    report = await deliver(maker, settings, senders, now)
    assert (report.dropped, report.sent) == (1, 0)
    assert senders["fcm"].sent == []
