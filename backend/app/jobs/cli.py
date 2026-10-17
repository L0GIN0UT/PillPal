"""Run one job from the command line: ``python -m app.jobs.account_erasure`` (or ``retention``).

The ARQ worker (``app.worker``) runs these jobs on a schedule; this entry point is for a one-off
run from a shell (or a cron on a host without the worker). A deployment needs one of the two:
nothing else ever completes a deletion. The exit code is 1 when a job reports failures.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from typing import Protocol

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings
from app.db.session import create_engine, create_sessionmaker
from app.observability import configure_logging


class _Report(Protocol):
    @property
    def failed(self) -> int: ...


Job = Callable[[async_sessionmaker[AsyncSession], Settings], Awaitable[_Report]]


async def run_cli(job: Job, settings: Settings) -> int:
    """Run ``job`` against the configured database; the process exit code."""
    engine = create_engine(settings)
    try:
        report = await job(create_sessionmaker(engine), settings)
    finally:
        await engine.dispose()
    return 1 if report.failed else 0


def main(job: Job) -> int:
    settings = Settings()
    configure_logging(settings.log_level)
    return asyncio.run(run_cli(job, settings))
