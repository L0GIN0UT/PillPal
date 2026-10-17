"""Helpers of the worker suites: a burst ARQ worker on the real Redis with injected ctx."""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from typing import Any

from arq import create_pool
from arq.connections import ArqRedis, RedisSettings
from arq.worker import Worker

from app.config import Settings
from app.push.base import PushProvider, PushSender
from app.worker import WorkerSettings, deserialize_job, on_shutdown, on_startup, serialize_job
from tests.conftest import TEST_REDIS_URL


async def open_pool() -> ArqRedis:
    return await create_pool(
        RedisSettings.from_dsn(TEST_REDIS_URL),
        job_serializer=serialize_job,
        job_deserializer=deserialize_job,
    )


async def run_burst(
    settings: Settings,
    senders: dict[PushProvider, PushSender] | dict[PushProvider, Any],
    now: Callable[[], datetime],
    *functions: str,
) -> Worker:
    """Enqueue ``functions`` and let a burst worker run them to completion (it closes the pool)."""
    pool = await open_pool()
    for name in functions:
        await pool.enqueue_job(name)
    worker = Worker(
        functions=WorkerSettings.functions,
        cron_jobs=[],  # crons are asserted separately; here the jobs are enqueued by name
        redis_pool=pool,
        burst=True,
        on_startup=on_startup,
        on_shutdown=on_shutdown,
        ctx={"settings": settings, "senders": senders, "now": now},
        job_serializer=serialize_job,
        job_deserializer=deserialize_job,
        keep_result=WorkerSettings.keep_result,
        log_results=False,
        handle_signals=False,
        poll_delay=0.05,
    )
    try:
        await worker.main()
    finally:
        await worker.close()
    return worker
