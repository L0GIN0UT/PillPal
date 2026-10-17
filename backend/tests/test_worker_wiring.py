"""``app.worker``: ARQ wiring, JSON serialization, no kept results, crons (ADR 0007, 0010)."""

from __future__ import annotations

import json
from datetime import timedelta

import pytest
from arq.connections import RedisSettings
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.push.fake import FakePushSender
from app.worker import (
    ERASE_CRON_INTERVAL_SECONDS,
    WorkerSettings,
    build_redis_settings,
    deserialize_job,
    on_shutdown,
    on_startup,
    serialize_job,
)
from tests.conftest import TEST_REDIS_URL, FakeClock, make_settings
from tests.grace_helpers import in_days, request_deletion
from tests.helpers import register
from tests.push_helpers import put_token
from tests.push_outbox_helpers import fake_senders, insert_outbox, outbox_rows
from tests.worker_helpers import run_burst

JOBS = {"deliver_pushes", "erase_expired_accounts", "cleanup_retention"}


def _names(items: list[object]) -> set[str]:
    return {getattr(item, "name", None) or getattr(item, "__name__", "") for item in items}


def test_the_worker_registers_the_jobs_and_their_crons() -> None:
    assert _names(WorkerSettings.functions) == JOBS
    assert _names(WorkerSettings.cron_jobs) == JOBS
    crons = {cron.name: cron for cron in WorkerSettings.cron_jobs}
    assert crons["deliver_pushes"].second == {0, 10, 20, 30, 40, 50}
    assert crons["deliver_pushes"].minute is None  # every minute
    assert (crons["erase_expired_accounts"].minute, crons["erase_expired_accounts"].hour) == (
        5,
        None,
    )  # hourly
    assert (crons["cleanup_retention"].hour, crons["cleanup_retention"].minute) == (3, 15)  # daily


def test_no_job_keeps_its_result() -> None:
    assert WorkerSettings.keep_result == 0
    assert all(function.keep_result_s in (0, None) for function in WorkerSettings.functions)
    assert all(
        not cron.keep_result_forever and cron.keep_result_s == 0
        for cron in WorkerSettings.cron_jobs
    )


def test_the_erase_cron_matches_the_interval_the_deletion_margin_assumes() -> None:
    assert (
        ERASE_CRON_INTERVAL_SECONDS == make_settings().account_erasure_job_interval_seconds == 3600
    )


def test_jobs_are_serialized_as_json_never_pickle() -> None:
    assert WorkerSettings.job_serializer is serialize_job
    assert WorkerSettings.job_deserializer is deserialize_job
    payload = {"t": 1, "f": "deliver_pushes", "a": (1, "x"), "k": {}, "et": 1760000000000}
    raw = serialize_job(payload)
    assert json.loads(raw) == {**payload, "a": [1, "x"]}
    assert deserialize_job(raw)["f"] == "deliver_pushes"
    with pytest.raises(TypeError):
        serialize_job({"a": (object(),)})  # anything that is not JSON is refused, not pickled
    with pytest.raises(ValueError, match=r"."):
        deserialize_job(b"\x80\x04\x95")  # a pickle stream is not accepted


def test_redis_settings_are_derived_from_the_redis_url_setting(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("REGION", "ru")
    monkeypatch.setenv("JWT_SECRET", "test-secret-test-secret-test-secret-0123")
    monkeypatch.setenv("REDIS_URL", "redis://:s3cret@redis:6379/3")
    parsed = build_redis_settings()
    assert isinstance(parsed, RedisSettings)
    assert (parsed.password, parsed.host, parsed.database) == ("s3cret", "redis", 3)


def test_the_worker_class_uses_that_single_source() -> None:
    expected = build_redis_settings()
    actual = WorkerSettings.redis_settings
    assert isinstance(actual, RedisSettings)
    assert (actual.host, actual.port, actual.database) == (
        expected.host,
        expected.port,
        expected.database,
    )


def test_the_health_check_is_frequent_enough_for_the_container_probe() -> None:
    assert WorkerSettings.health_check_interval <= 60


async def test_startup_builds_the_dependencies_and_shutdown_releases_them() -> None:
    ctx: dict[str, object] = {"settings": make_settings()}
    await on_startup(ctx)
    try:
        assert {"settings", "engine", "maker", "senders", "now"} <= set(ctx)
        assert set(ctx["senders"]) == {"fcm", "apns", "rustore"}  # type: ignore[call-overload]
        moment = ctx["now"]()  # type: ignore[operator]
        assert moment.tzinfo is not None
    finally:
        await on_shutdown(ctx)


async def test_startup_keeps_injected_dependencies() -> None:
    fakes = fake_senders()
    clock = FakeClock()
    ctx: dict[str, object] = {"settings": make_settings(), "senders": fakes, "now": clock}
    await on_startup(ctx)
    try:
        assert ctx["senders"] is fakes
        assert ctx["now"] is clock
    finally:
        await on_shutdown(ctx)
    assert isinstance(fakes["fcm"], FakePushSender)


async def test_startup_refuses_an_erase_interval_the_cron_does_not_match() -> None:
    ctx: dict[str, object] = {"settings": make_settings(account_erasure_job_interval_seconds=1800)}
    with pytest.raises(RuntimeError, match="ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS"):
        await on_startup(ctx)


async def test_a_burst_worker_delivers_pushes_on_real_redis_and_keeps_no_result(
    client: AsyncClient, engine: AsyncEngine, settings: Settings
) -> None:
    user = await register(client)
    await put_token(client, user)
    await insert_outbox(engine, user, user.self_profile_id)
    clock = FakeClock()
    clock.advance(seconds=5)
    senders = fake_senders()
    worker = await run_burst(settings, senders, clock, "deliver_pushes")
    assert (worker.jobs_complete, worker.jobs_failed) == (1, 0)
    assert len(senders["fcm"].sent) == 1
    assert [r.status for r in await outbox_rows(engine)] == ["sent"]
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    try:
        # ``keep_result=0``: nothing of a finished job (arguments, return value) stays in Redis.
        assert [key async for key in redis.scan_iter("arq:result:*")] == []
        assert [key async for key in redis.scan_iter("arq:job:*")] == []
    finally:
        await redis.aclose()


async def test_a_burst_worker_runs_the_erase_job_for_due_accounts(
    client: AsyncClient, engine: AsyncEngine, settings: Settings
) -> None:
    user, bystander = await register(client), await register(client)
    assert (await request_deletion(client, user)).status_code == 204
    clock = FakeClock()
    clock.now = in_days(31)
    worker = await run_burst(settings, fake_senders(), clock, "erase_expired_accounts")
    assert (worker.jobs_complete, worker.jobs_failed) == (1, 0)
    from tests.push_helpers import rows

    left = {r.id for r in await rows(engine, "SELECT id FROM users")}
    assert {str(i) for i in left} == {bystander.id}


async def test_a_burst_worker_runs_all_three_jobs(
    client: AsyncClient, engine: AsyncEngine, settings: Settings
) -> None:
    clock = FakeClock()
    clock.now = in_days(0) + timedelta(seconds=5)
    worker = await run_burst(
        settings,
        fake_senders(),
        clock,
        "deliver_pushes",
        "erase_expired_accounts",
        "cleanup_retention",
    )
    assert (worker.jobs_complete, worker.jobs_failed) == (3, 0)
