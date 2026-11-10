"""The export builder: a cron every minute that turns requests into encrypted archives
(ADR 0016 section 8).

Each run, in this order:

1. ``ready`` exports past ``expires_at`` become ``expired`` and lose their archive;
2. ``running`` exports whose lease expired are marked ``failed`` / ``export_build_failed``: a
   worker that died mid-build is not retried (a build that kills its worker would kill the next
   one too; the user asks again);
3. metadata rows older than ``EXPORT_RETENTION_DAYS`` (counted from the request) are deleted,
   never a ``ready`` one (``EXPORT_TTL_HOURS`` is validated to expire it first);
4. up to ``EXPORT_BUILDS_PER_RUN`` ``queued`` requests are built, at most one per account per
   run. A request is *claimed* with ``FOR UPDATE SKIP LOCKED`` and marked ``running`` with a
   lease; the claim commits before the long work, and the result is written only if the lease
   is still ours. Accounts that are pending deletion are skipped (a deletion request deletes
   their exports anyway). The clock is read again for every build.

Steps 1 to 3 run even while ``FEATURE_DATA_EXPORT`` is off, so turning the feature off never
leaves an archive behind. The build itself reads one consistent snapshot
(``collect_account_data``), zips it (``build_archive``, in a thread, aborting once it passes
``EXPORT_MAX_BYTES``: ``export_too_large``) and encrypts it under the current key. A cancelled
build is finished as ``export_build_failed`` and the cancellation re-raised. The job logs export
ids, outcomes and exception types only: the archive is medical data.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings
from app.db.exports import DataExport
from app.db.models import User
from app.observability import get_logger
from app.services.data_encryption import EXPORT_PURPOSE, DataKeyring
from app.services.export_archive import ArchiveTooLarge, build_archive, collect_account_data

_log = get_logger("pillpal.jobs.data_exports")


@dataclass(frozen=True)
class ExportBuildReport:
    expired: int = 0
    abandoned: int = 0
    deleted: int = 0
    built: int = 0
    failed: int = 0


@dataclass(frozen=True)
class _Claim:
    export_id: uuid.UUID
    user_id: uuid.UUID
    lease_until: datetime


@dataclass(frozen=True)
class _Built:
    blob: bytes
    size_bytes: int  # the zip, not the ciphertext


class ExportTooLarge(Exception):
    """The finished archive is over ``EXPORT_MAX_BYTES``."""


async def _expire(session: AsyncSession, now: datetime) -> int:
    result = await session.execute(
        update(DataExport)
        .where(DataExport.status == "ready", DataExport.expires_at <= now)
        .values(status="expired", archive=None)
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def _abandon_dead_builds(session: AsyncSession, now: datetime) -> int:
    result = await session.execute(
        update(DataExport)
        .where(DataExport.status == "running", DataExport.lease_until <= now)
        .values(status="failed", error_code="export_build_failed", lease_until=None)
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def _delete_old(session: AsyncSession, settings: Settings, now: datetime) -> int:
    cutoff = now - timedelta(days=settings.export_retention_days)
    result = await session.execute(
        delete(DataExport)
        .where(DataExport.requested_at <= cutoff, DataExport.status != "ready")
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def _claim(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: datetime,
    seen_users: set[uuid.UUID],
) -> _Claim | None:
    async with maker() as session:
        pending = select(User.id).where(User.deletion_requested_at.is_not(None))
        row = (
            await session.execute(
                select(DataExport.id, DataExport.user_id)
                .where(
                    DataExport.status == "queued",
                    DataExport.user_id.not_in(pending),
                    DataExport.user_id.not_in(seen_users),
                )
                .order_by(DataExport.requested_at, DataExport.id)
                .limit(1)
                .with_for_update(skip_locked=True)
            )
        ).first()
        if row is None:
            return None
        lease = now + timedelta(seconds=settings.export_build_lease_seconds)
        await session.execute(
            update(DataExport)
            .where(DataExport.id == row.id)
            .values(status="running", lease_until=lease)
            .execution_options(synchronize_session=False)
        )
        await session.commit()
        return _Claim(row.id, row.user_id, lease)


async def _build(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    keyring: DataKeyring,
    claim: _Claim,
    now: datetime,
) -> _Built:
    async with maker() as session:
        data = await collect_account_data(session, claim.user_id)
    try:
        archive = await asyncio.to_thread(
            build_archive,
            data,
            region=settings.region,
            now=now,
            max_bytes=settings.export_max_bytes,
        )
    except ArchiveTooLarge:
        raise ExportTooLarge from None
    if len(archive) > settings.export_max_bytes:
        raise ExportTooLarge
    blob = await asyncio.to_thread(keyring.encrypt, EXPORT_PURPOSE, claim.export_id, archive)
    return _Built(blob, len(archive))


async def _finish(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    claim: _Claim,
    now: datetime,
    *,
    built: _Built | None,
    error_code: str | None,
) -> bool:
    """Record the result if the lease is still ours and the account is not pending deletion."""
    values: dict[str, object] = {"lease_until": None}
    if built is not None:
        values |= {
            "status": "ready",
            "archive": built.blob,
            "size_bytes": built.size_bytes,
            "ready_at": now,
            "expires_at": now + timedelta(hours=settings.export_ttl_hours),
        }
    else:
        values |= {"status": "failed", "error_code": error_code}
    async with maker() as session:
        pending = select(User.id).where(User.deletion_requested_at.is_not(None))
        result = await session.execute(
            update(DataExport)
            .where(
                DataExport.id == claim.export_id,
                DataExport.status == "running",
                DataExport.lease_until == claim.lease_until,
                DataExport.user_id.not_in(pending),
            )
            .values(**values)
            .execution_options(synchronize_session=False)
        )
        await session.commit()
        return int(result.rowcount) == 1  # type: ignore[attr-defined]


async def _fail_quietly(
    maker: async_sessionmaker[AsyncSession], settings: Settings, claim: _Claim, now: datetime
) -> None:
    """Best effort while being cancelled: a row left ``running`` is failed by the next run."""
    try:
        await asyncio.shield(
            _finish(maker, settings, claim, now, built=None, error_code="export_build_failed")
        )
    except Exception as exc:
        _log.error(
            "export_finish_failed", export_id=str(claim.export_id), exc_type=type(exc).__name__
        )


async def _build_one(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    keyring: DataKeyring,
    claim: _Claim,
    now: Callable[[], datetime],
) -> bool:
    """Build and record one export; ``True`` when it became ``ready``."""
    try:
        built = await _build(maker, settings, keyring, claim, now())
    except ExportTooLarge:
        await _finish(maker, settings, claim, now(), built=None, error_code="export_too_large")
        _log.info("export_failed", export_id=str(claim.export_id), error_code="export_too_large")
        return False
    except asyncio.CancelledError:
        # Never retried: the job timeout or a shutdown killed the build.
        _log.error("export_cancelled", export_id=str(claim.export_id))
        await _fail_quietly(maker, settings, claim, now())
        raise
    except Exception as exc:
        # The type only: a message may embed row values.
        _log.error(
            "export_failed",
            export_id=str(claim.export_id),
            error_code="export_build_failed",
            exc_type=type(exc).__name__,
        )
        await _finish(maker, settings, claim, now(), built=None, error_code="export_build_failed")
        return False
    recorded = await _finish(maker, settings, claim, now(), built=built, error_code=None)
    _log.info("export_ready" if recorded else "export_superseded", export_id=str(claim.export_id))
    return recorded


async def build_data_exports(
    maker: async_sessionmaker[AsyncSession], settings: Settings, *, now: Callable[[], datetime]
) -> ExportBuildReport:
    start = now()
    async with maker() as session:
        expired = await _expire(session, start)
        abandoned = await _abandon_dead_builds(session, start)
        deleted = await _delete_old(session, settings, start)
        await session.commit()
    keyring = DataKeyring.from_settings(settings) if settings.feature_data_export else None
    built = failed = 0
    seen_users: set[uuid.UUID] = set()
    for _ in range(settings.export_builds_per_run):
        if keyring is None:
            break
        claim = await _claim(maker, settings, now(), seen_users)
        if claim is None:
            break
        seen_users.add(claim.user_id)
        if await _build_one(maker, settings, keyring, claim, now):
            built += 1
        else:
            failed += 1
    if expired or abandoned or deleted or built or failed:
        _log.info(
            "data_exports_run",
            expired=expired,
            abandoned=abandoned,
            deleted=deleted,
            built=built,
            failed=failed,
        )
    return ExportBuildReport(expired, abandoned, deleted, built, failed)
