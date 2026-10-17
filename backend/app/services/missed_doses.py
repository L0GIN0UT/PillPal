"""The missed-dose detector tick (ADR 0007 §2): one window per tick, one tick at a time.

``detect_missed_doses`` is what the ARQ cron runs every minute:

1. a session-level ``pg_try_advisory_lock`` is held for the whole tick on a dedicated connection
   (a transaction-level lock would be released by the first per-batch commit and let ticks
   overlap); if another tick holds it, this one is skipped;
2. the window ``[watermark, end)`` is at most ``DETECTOR_MAX_WINDOW_SECONDS`` long, and after more
   than ``DETECTOR_MAX_CATCHUP_SECONDS`` of downtime the start skips ahead (the skipped span is
   logged as a count of seconds);
3. eligible profiles are paged by id and each page is one transaction (``missed_batch``);
4. the watermark moves to the end of the window in the last transaction, only forward. A tick
   that fails halfway leaves it, so the whole window is retried; the alert insert is
   ``ON CONFLICT DO NOTHING``, so nothing is alerted twice.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Final

from sqlalchemy import func, literal, select, update
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncSession, async_sessionmaker

from app.config import Settings
from app.db.alerts import DETECTOR_NAME, DetectorState
from app.domain.missed import DetectionWindow, next_window
from app.observability import get_logger
from app.services.missed_batch import BatchResult, process_batch
from app.services.missed_queries import eligible_page

_log = get_logger("pillpal.detector")

# Hashed to the bigint key of the session lock; journal locks hash owner ids, a separate domain.
DETECTOR_LOCK_NAME: Final = "pillpal.missed_dose_detector"
# Re-reads of profiles whose owner changed between the page and the lock (practically never > 1).
MAX_OWNER_RETRIES: Final = 3


@dataclass(frozen=True, slots=True)
class TickReport:
    ran: bool  # False: another tick held the lock
    window: DetectionWindow | None = None
    batches: int = 0
    profiles: int = 0
    alerts: int = 0
    pushes: int = 0
    skipped_seconds: int = 0


def _lock_key() -> object:
    return func.hashtextextended(literal(DETECTOR_LOCK_NAME), 0)


async def _release(connection: AsyncConnection) -> None:
    """Unlock; a connection that cannot prove it did is closed, which drops the lock."""
    try:
        released = (await connection.execute(select(func.pg_advisory_unlock(_lock_key())))).scalar()
    except Exception as exc:
        _log.error("detector_unlock_failed", exc_type=type(exc).__name__)
        released = False
    if not released:
        await connection.invalidate()


async def _run(
    maker: async_sessionmaker[AsyncSession], settings: Settings, now: datetime
) -> TickReport:
    async with maker() as session:
        watermark = await session.scalar(
            select(DetectorState.watermark).where(DetectorState.name == DETECTOR_NAME)
        )
    if watermark is None:
        raise RuntimeError("detector_state has no watermark row")
    window = next_window(
        watermark,
        now,
        max_window=timedelta(seconds=settings.detector_max_window_seconds),
        max_catchup=timedelta(seconds=settings.detector_max_catchup_seconds),
    )
    if window is None:
        return TickReport(ran=True)
    skipped = int(window.skipped.total_seconds())
    if skipped:
        _log.warning("detector_gap_skipped", skipped_seconds=skipped)
    report = await _page_through(maker, settings, window, now)
    async with maker() as session:
        # greatest(): a late tick of an older run must never move the watermark back.
        await session.execute(
            update(DetectorState)
            .where(DetectorState.name == DETECTOR_NAME)
            .values(watermark=func.greatest(DetectorState.watermark, window.end))
        )
        await session.commit()
    _log.info(
        "detector_tick",
        window_seconds=int((window.end - window.start).total_seconds()),
        batches=report.batches,
        profiles=report.profiles,
        alerts=report.alerts,
        pushes=report.pushes,
    )
    return TickReport(
        True,
        window,
        report.batches,
        report.profiles,
        report.alerts,
        report.pushes,
        skipped,
    )


async def _run_batch(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    window: DetectionWindow,
    page: Sequence[tuple[uuid.UUID, uuid.UUID]],
    now: datetime,
) -> tuple[BatchResult, int]:
    """One batch, then the profiles whose owner changed meanwhile under their new owners' locks
    (a hand-over, ADR 0010 D1); returns the summed result and the number of extra transactions."""
    total = BatchResult()
    extra = 0
    pending: Sequence[tuple[uuid.UUID, uuid.UUID]] = page
    for _ in range(MAX_OWNER_RETRIES + 1):
        async with maker() as session:
            result = await process_batch(session, settings, window, pending, now)
            await session.commit()
        total = BatchResult(
            total.profiles + result.profiles,
            total.alerts + result.alerts,
            total.pushes + result.pushes,
        )
        if not result.moved:
            return total, extra
        pending, extra = result.moved, extra + 1
    _log.warning("detector_owner_moved_repeatedly", profiles=len(pending))
    return total, extra


async def _page_through(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    window: DetectionWindow,
    now: datetime,
) -> TickReport:
    after: uuid.UUID | None = None
    batches = profiles = alerts = pushes = 0
    while True:
        async with maker() as session:
            page = await eligible_page(session, after, settings.detector_profile_batch)
        if not page:
            break
        result, extra = await _run_batch(maker, settings, window, page, now)
        batches += 1 + extra
        profiles += result.profiles
        alerts += result.alerts
        pushes += result.pushes
        after = page[-1][0]
        if len(page) < settings.detector_profile_batch:
            break
    return TickReport(True, window, batches, profiles, alerts, pushes)


async def detect_missed_doses(
    maker: async_sessionmaker[AsyncSession], settings: Settings, now: datetime
) -> TickReport:
    """Run one detector tick at ``now``; ``TickReport.ran`` is False if another tick is running."""
    async with maker() as lock_session:
        connection = await lock_session.connection(
            execution_options={"isolation_level": "AUTOCOMMIT"}
        )
        acquired = (
            await connection.execute(select(func.pg_try_advisory_lock(_lock_key())))
        ).scalar()
        if not acquired:
            _log.info("detector_tick_skipped")
            return TickReport(ran=False)
        try:
            return await _run(maker, settings, now)
        finally:
            await _release(connection)
