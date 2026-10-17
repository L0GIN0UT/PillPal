"""``deliver_pending``: claim, send, record (ADR 0008 §6)."""

from __future__ import annotations

import asyncio
import uuid
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
from tests.push_outbox_helpers import deliver, fake_senders, insert_outbox, outbox_rows


@pytest.fixture
def maker(
    app_and_engine: tuple[object, AsyncEngine], clean_state: None
) -> async_sessionmaker[AsyncSession]:
    return app_and_engine[0].state.sessionmaker  # type: ignore[attr-defined,no-any-return]


@pytest.fixture
def now() -> FakeClock:
    clock = FakeClock()
    # Rows are inserted with the database's now(); the injected clock starts just after it.
    clock.advance(seconds=5)
    return clock


async def _recipient(client: AsyncClient, engine: AsyncEngine, n: int = 1):  # type: ignore[no-untyped-def]
    user = await register(client)
    await put_token(client, user, "dev-1")
    ids = [await insert_outbox(engine, user, user.self_profile_id) for _ in range(n)]
    return user, ids


async def test_ok_marks_the_row_sent_and_the_token_successful(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    user, (row_id,) = await _recipient(client, engine)
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


async def test_retry_backs_off_30s_2min_10min_30min_then_drops(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await _recipient(client, engine)
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
    await _recipient(client, engine)
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
    await _recipient(client, engine)
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
    user, _ = await _recipient(client, engine, n=3)
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
    await _recipient(client, engine)
    senders = fake_senders()
    senders["fcm"].results = [SendResult.fatal("SENDER_ID_MISMATCH")]
    report = await deliver(maker, settings, senders, now)
    assert report.dropped == 1
    (row,) = await outbox_rows(engine)
    assert (row.status, row.last_error_code) == ("dropped", "SENDER_ID_MISMATCH")
    assert len(await rows(engine, "SELECT 1 FROM push_tokens")) == 1  # config error, token kept


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
    await _recipient(client, engine)
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
    await _recipient(client, engine, n=2)

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
    await _recipient(client, engine, n=60)
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

    await _recipient(client, engine)
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
    await _recipient(client, engine, n=10)
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
    await _recipient(client, engine, n=10)
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
    await _recipient(client, engine)
    now.advance(days=3)  # far past the real "now": the row is stale for this clock
    senders = fake_senders()
    report = await deliver(maker, settings, senders, now)
    assert (report.dropped, report.sent) == (1, 0)
    assert senders["fcm"].sent == []
