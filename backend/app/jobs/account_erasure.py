"""The hourly erase job: hard-erase accounts whose deletion grace period is over (ADR 0010 §5).

It loops over due accounts in batches until none is left. Every account has its own
transaction that takes the user row lock ``FOR NO KEY UPDATE SKIP LOCKED`` *inside* that
transaction and re-checks ``erase_after`` under it, so

* a restore that holds the row (or committed first) makes the job skip the account;
* a job that holds the row makes a restore wait and then find the account gone: exactly
  one of the two wins;
* several workers never erase one account twice.

One account that fails does not stop the others and is not retried within the run (it would
loop for ever); it is logged with its id and the exception *type* only, and counted.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings
from app.db.models import User
from app.observability import get_logger
from app.services.erasure import erase_account

_log = get_logger("pillpal.jobs.account_erasure")


@dataclass(frozen=True)
class ErasureReport:
    erased: int = 0
    failed: int = 0
    # Accounts that were due more than one job interval ago and are still not erased: the
    # job fell behind (alert on it; the 30-day limit of 152-FZ art. 21(5) is at stake).
    overdue: int = 0
    erased_ids: list[uuid.UUID] = field(default_factory=list)


async def erasure_overdue_count(session: AsyncSession, settings: Settings, now: datetime) -> int:
    """Accounts due for longer than one job interval (``erasure_overdue_count``)."""
    cutoff = now - timedelta(seconds=settings.account_erasure_job_interval_seconds)
    count = await session.scalar(
        select(func.count()).select_from(User).where(User.erase_after <= cutoff)
    )
    return int(count or 0)


async def _erase_one(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    user_id: uuid.UUID,
    now: datetime,
    *,
    wait: bool = False,
) -> bool:
    """Erase one account if it is still due; ``False`` when it was restored, erased or locked.

    ``wait`` is the end-of-run retry: it blocks on the row (bounded by ``lock_timeout``)
    instead of skipping it, so a restore in flight cannot push the erasure past its deadline.
    """
    async with maker() as session:
        if wait:
            timeout_ms = settings.account_erasure_retry_lock_timeout_seconds * 1000
            # set_config(..., true) = SET LOCAL, with a bound parameter instead of SQL text.
            await session.execute(select(func.set_config("lock_timeout", str(timeout_ms), True)))
        # Under the lock the WHERE is re-evaluated: a restore that held the row wins.
        locked = await session.scalar(
            select(User.id)
            .where(User.id == user_id, User.erase_after <= now)
            .with_for_update(skip_locked=not wait, key_share=True)
        )
        if locked is None:
            return False
        await erase_account(
            session,
            user_id,
            now=now,
            managed_archive_retention_days=settings.managed_archive_retention_days,
        )
        await session.commit()
    _log.info("account_erased", user_id=str(user_id))
    return True


async def _retry_skipped(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    skipped: set[uuid.UUID],
    now: datetime,
) -> list[uuid.UUID]:
    """One blocking pass over the accounts that were locked during the main loop."""
    erased: list[uuid.UUID] = []
    for user_id in sorted(skipped):
        try:
            if await _erase_one(maker, settings, user_id, now, wait=True):
                erased.append(user_id)
        except DBAPIError as exc:  # lock_timeout: still held; the next run is in time (margin)
            _log.warning(
                "account_erase_retry_failed", user_id=str(user_id), exc_type=type(exc).__name__
            )
    return erased


async def erase_expired_accounts(
    maker: async_sessionmaker[AsyncSession], settings: Settings, *, now: datetime | None = None
) -> ErasureReport:
    """Erase every account that is due at ``now``; loops until none is left."""
    now = now or datetime.now(UTC)
    erased: list[uuid.UUID] = []
    failed: set[uuid.UUID] = set()
    skipped: set[uuid.UUID] = set()
    while True:
        async with maker() as session:
            due = (
                await session.scalars(
                    select(User.id)
                    .where(User.erase_after <= now, User.id.not_in(failed | skipped))
                    .order_by(User.erase_after, User.id)
                    .limit(settings.account_erasure_batch_size)
                )
            ).all()
        if not due:
            break
        for user_id in due:
            try:
                if await _erase_one(maker, settings, user_id, now):
                    erased.append(user_id)
                else:
                    skipped.add(user_id)  # restored or held by a concurrent restore
            except Exception as exc:
                # Type only: messages may embed SQL parameters, i.e. personal data.
                _log.error(
                    "account_erase_failed", user_id=str(user_id), exc_type=type(exc).__name__
                )
                failed.add(user_id)
    erased += await _retry_skipped(maker, settings, skipped, now)
    async with maker() as session:
        overdue = await erasure_overdue_count(session, settings, now)
    _log.info(
        "erase_expired_accounts",
        erased=len(erased),
        failed=len(failed),
        erasure_overdue_count=overdue,
    )
    return ErasureReport(len(erased), len(failed), overdue, erased)


def main() -> int:
    from app.jobs.cli import main as run

    return run(erase_expired_accounts)


if __name__ == "__main__":
    raise SystemExit(main())
