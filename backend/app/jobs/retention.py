"""Retention: what is kept only for a while (ADR 0009 §6, ADR 0005 §5, ``docs/phase3-plan.md``).

Daily, as an ARQ cron (``app.worker``); also runnable as ``python -m app.jobs.retention``.

* ``invites.consumed_by_user_id`` is forgotten after ``INVITE_REPLAY_WINDOW_SECONDS`` (it only
  exists so a lost accept response can be replayed);
* invites are deleted ``INVITE_RETENTION_DAYS`` after their end of life: consumed, revoked, or
  expired;
* managed-profile archives are purged at ``archive_purge_after`` (a purge, not a tombstone:
  ``app.services.archives``), each in its own transaction under its owner's journal lock.

* push outbox rows (ADR 0008 §6): ``sent`` ones after ``PUSH_SENT_RETENTION_HOURS`` (24 h), every
  other row after ``PUSH_OUTBOX_RETENTION_DAYS`` (7 days);
* push tokens without a successful delivery (or registration) for ``PUSH_TOKEN_STALE_DAYS`` (270
  days, when FCM treats a registration as expired).

* missed-dose alerts (ADR 0007 §6) ``DETECTOR_ALERT_RETENTION_HOURS`` (72 h) after detection: they
  only serve dedupe and ``resolved``, and the 6 h catch-up plus the 2 h push staleness never need
  them longer.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, delete, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings
from app.db.alerts import MissedDoseAlert
from app.db.models import Profile
from app.db.push import PushOutbox, PushToken
from app.db.relatives import Invite
from app.observability import get_logger
from app.services.archives import purge_profiles
from app.services.changes import lock_journal

_log = get_logger("pillpal.jobs.retention")


@dataclass(frozen=True)
class RetentionReport:
    invite_accepters_forgotten: int = 0
    invites_deleted: int = 0
    archives_purged: int = 0
    archives_failed: int = 0
    push_outbox_deleted: int = 0
    push_tokens_deleted: int = 0
    missed_alerts_deleted: int = 0

    @property
    def failed(self) -> int:
        return self.archives_failed


async def _forget_invite_accepters(session: AsyncSession, settings: Settings, now: datetime) -> int:
    window = timedelta(seconds=settings.invite_replay_window_seconds)
    result = await session.execute(
        update(Invite)
        .where(Invite.consumed_by_user_id.is_not(None), Invite.consumed_at <= now - window)
        .values(consumed_by_user_id=None)
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def _delete_old_invites(session: AsyncSession, settings: Settings, now: datetime) -> int:
    # An invite ends when it is consumed or revoked (never both), else when it expires.
    ended = func.coalesce(Invite.consumed_at, Invite.revoked_at, Invite.expires_at)
    cutoff = now - timedelta(days=settings.invite_retention_days)
    result = await session.execute(
        delete(Invite).where(ended <= cutoff).execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def _delete_old_push_rows(session: AsyncSession, settings: Settings, now: datetime) -> int:
    sent_before = now - timedelta(hours=settings.push_sent_retention_hours)
    any_before = now - timedelta(days=settings.push_outbox_retention_days)
    result = await session.execute(
        delete(PushOutbox)
        .where(
            or_(
                and_(PushOutbox.status == "sent", PushOutbox.sent_at <= sent_before),
                PushOutbox.created_at <= any_before,
            )
        )
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def _delete_old_alerts(session: AsyncSession, settings: Settings, now: datetime) -> int:
    cutoff = now - timedelta(hours=settings.detector_alert_retention_hours)
    result = await session.execute(
        delete(MissedDoseAlert)
        .where(MissedDoseAlert.detected_at <= cutoff)
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def _delete_stale_push_tokens(
    session: AsyncSession, settings: Settings, now: datetime
) -> int:
    # A token that never delivered counts from its (re-)registration. Its pending rows cascade.
    last_alive = func.coalesce(PushToken.last_success_at, PushToken.updated_at)
    cutoff = now - timedelta(days=settings.push_token_stale_days)
    result = await session.execute(
        delete(PushToken).where(last_alive <= cutoff).execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def _purge_one_archive(
    maker: async_sessionmaker[AsyncSession], profile_id: uuid.UUID, now: datetime
) -> bool:
    async with maker() as session:
        owner_id = await session.scalar(
            select(Profile.owner_user_id).where(Profile.id == profile_id)
        )
        if owner_id is None:
            return False
        await lock_journal(session, [owner_id])
        # Re-checked under the lock: a hand-over or a purge may have happened meanwhile.
        due = await session.scalar(
            select(Profile.id)
            .where(
                Profile.id == profile_id,
                Profile.owner_user_id == owner_id,
                Profile.archive_purge_after <= now,
            )
            .with_for_update()
        )
        if due is None:
            return False
        await purge_profiles(session, [profile_id])
        await session.commit()
    _log.info("archive_purged", profile_id=str(profile_id))
    return True


async def cleanup_retention(
    maker: async_sessionmaker[AsyncSession], settings: Settings, *, now: datetime | None = None
) -> RetentionReport:
    now = now or datetime.now(UTC)
    async with maker() as session:
        forgotten = await _forget_invite_accepters(session, settings, now)
        deleted = await _delete_old_invites(session, settings, now)
        push_rows = await _delete_old_push_rows(session, settings, now)
        push_tokens = await _delete_stale_push_tokens(session, settings, now)
        alerts = await _delete_old_alerts(session, settings, now)
        await session.commit()
        expired = (
            await session.scalars(
                select(Profile.id).where(Profile.archive_purge_after <= now).order_by(Profile.id)
            )
        ).all()
    purged = failed = 0
    for profile_id in expired:
        try:
            purged += await _purge_one_archive(maker, profile_id, now)
        except Exception as exc:
            # Type only: messages may embed SQL parameters, i.e. medical data.
            _log.error(
                "archive_purge_failed", profile_id=str(profile_id), exc_type=type(exc).__name__
            )
            failed += 1
    report = RetentionReport(forgotten, deleted, purged, failed, push_rows, push_tokens, alerts)
    _log.info(
        "cleanup_retention",
        invite_accepters_forgotten=forgotten,
        invites_deleted=deleted,
        archives_purged=purged,
        archives_failed=failed,
        push_outbox_deleted=push_rows,
        push_tokens_deleted=push_tokens,
        missed_alerts_deleted=alerts,
    )
    return report


def main() -> int:
    from app.jobs.cli import main as run

    return run(cleanup_retention)


if __name__ == "__main__":
    raise SystemExit(main())
