"""Account deletion with a grace period (owner decision D2, ADR 0010).

``DELETE /v1/me`` does not erase. :func:`request_deletion` marks the account
``pending_deletion`` (``deletion_requested_at`` set), which in one transaction

* sets ``erase_after = now + ACCOUNT_DELETION_GRACE_DAYS - ACCOUNT_ERASURE_JOB_INTERVAL``,
  so the hourly job erases no later than the grace period counted from the request even if
  one run is missed or one account has to be retried;
* sets ``tokens_not_before`` (every access token issued earlier stops working) and revokes
  every refresh-token family;
* revokes the account's open invites;
* archives its managed profiles (D1);
* ends access for relatives: a grant is *active* only while neither its grantee nor the
  profile's owner is pending (``app.services.access.grant_is_active``), so the account's
  profiles and its own grants vanish from every query and pull without any row changing.

:func:`apply_restore` is the reverse; it runs inside ``AuthService.restore`` after the
restore ticket and the mailed code were checked. The hard erase is
``app.services.erasure`` (called by ``app.jobs.account_erasure``).

The user row is locked ``FOR NO KEY UPDATE`` everywhere: it serializes login, refresh,
restore, the request and the job, but - unlike ``FOR UPDATE`` - it does not conflict with
the ``KEY SHARE`` lock every foreign-key check on ``users`` takes, so a request cannot
deadlock with a sync push that holds its journal lock and inserts a device or a profile.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import ERASE_MARGIN_INTERVALS, Settings
from app.db.models import Profile, RefreshToken, User
from app.db.push import PushToken
from app.db.relatives import Invite, ProfileGrant
from app.errors import unauthorized
from app.observability import get_logger
from app.push.base import PushPayload
from app.services.archives import archive_owned_profiles, unarchive_owned_profiles
from app.services.changes import lock_journal
from app.services.push_outbox import drop_pending_about_profiles_of, enqueue

_log = get_logger("pillpal.account_deletion")


def wall_clock() -> datetime:
    """The clock access tokens use (``iat``); ``tokens_not_before`` is compared with it."""
    return datetime.now(UTC)


async def lock_user(session: AsyncSession, user_id: uuid.UUID) -> User | None:
    """The user row, locked until the transaction ends and freshly read.

    Sessions here do not autoflush, and the re-read overwrites the loaded instance: pending
    changes are flushed first (a verified e-mail must not be lost to the lock).
    """
    await session.flush()
    return await session.scalar(
        select(User)
        .where(User.id == user_id)
        .with_for_update(key_share=True)
        .execution_options(populate_existing=True)
    )


def erase_after_for(settings: Settings, now: datetime) -> datetime:
    grace = timedelta(days=settings.account_deletion_grace_days)
    margin = timedelta(
        seconds=ERASE_MARGIN_INTERVALS * settings.account_erasure_job_interval_seconds
    )
    return now + grace - margin


async def request_deletion(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID, now: datetime
) -> datetime:
    """Start the grace period; returns ``erase_after``. The caller commits and mails.

    A request that finds the account already pending (two at once) is answered like any
    unauthenticated call: the first one won.
    """
    user = await lock_user(session, user_id)
    if user is None or user.pending_deletion:
        raise unauthorized()
    # After the row lock, like ``restore``: pushes in flight finish before the profiles are
    # archived, and later ones see the archive.
    await lock_journal(session, [user_id])
    erase_after = erase_after_for(settings, now)
    user.deletion_requested_at = now
    user.erase_after = erase_after
    user.tokens_not_before = wall_clock()
    user.updated_at = now
    await session.execute(
        update(RefreshToken)
        .where(RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=now)
        .execution_options(synchronize_session=False)
    )
    owned = select(Profile.id).where(Profile.owner_user_id == user_id)
    await session.execute(
        update(Invite)
        .where(
            Invite.consumed_at.is_(None),
            Invite.revoked_at.is_(None),
            (Invite.created_by_user_id == user_id) | Invite.profile_id.in_(owned),
        )
        .values(revoked_at=now)
        .execution_options(synchronize_session=False)
    )
    archived = await archive_owned_profiles(session, user_id, now)
    await drop_push_delivery(session, user_id)
    _log.info("deletion_requested", user_id=str(user_id), archived_profiles=archived)
    return erase_after


async def apply_restore(session: AsyncSession, user: User, now: datetime) -> None:
    """Undo the request on a locked pending ``user``; the caller holds the journal lock."""
    user.deletion_requested_at = None
    user.erase_after = None
    user.tokens_not_before = wall_clock()
    user.updated_at = now
    unarchived = await unarchive_owned_profiles(session, user.id)
    _log.info("account_restored", user_id=str(user.id), unarchived_profiles=unarchived)


# --- push (milestone 3.4, ADR 0008) ----------------------------------------------------------


async def drop_push_delivery(session: AsyncSession, user_id: uuid.UUID) -> None:
    """Delete the account's push tokens and drop pending outbox rows about its profiles.

    Tokens first: their pending rows (pushes *to* this account) cascade. Rows about the
    account's profiles that were queued for relatives are marked ``dropped/access_changed``
    in this very transaction; the send-time check would stop them anyway, but nothing about
    the account should stay queued once the request commits.
    """
    await session.execute(
        delete(PushToken)
        .where(PushToken.user_id == user_id)
        .execution_options(synchronize_session=False)
    )
    await drop_pending_about_profiles_of(session, user_id)


@dataclass(frozen=True)
class HeldGrant:
    """A grant the restored account holds: whom to tell (the profile's owner) and about what."""

    grant_id: uuid.UUID
    profile_id: uuid.UUID
    owner_id: uuid.UUID


async def grants_held_by(session: AsyncSession, user_id: uuid.UUID) -> list[HeldGrant]:
    """The grants of the account on live profiles (a restore notifies each profile's owner)."""
    rows = await session.execute(
        select(ProfileGrant.id, Profile.id, Profile.owner_user_id)
        .join(Profile, Profile.id == ProfileGrant.profile_id)
        .where(ProfileGrant.grantee_user_id == user_id, Profile.deleted_at.is_(None))
        .order_by(ProfileGrant.created_at, ProfileGrant.id)
    )
    return [HeldGrant(*row) for row in rows]


async def enqueue_link_restored(
    session: AsyncSession, *, grants: list[HeldGrant], now: datetime
) -> None:
    """Tell each owner that a relative's link is active again (``link_restored``, ids only).

    Enqueued in the restoring transaction. Owners without a push token still see the link
    as ``active: true`` again in ``GET /v1/grants`` (the Family tab's banner). The restore
    instant is part of the dedupe reference: a second deletion and restore tells them again.
    """
    stamp = int(now.timestamp() * 1_000_000)
    for held in grants:
        await enqueue(
            session,
            recipient_user_id=held.owner_id,
            payload=PushPayload(t="link_restored", p=held.profile_id, g=held.grant_id),
            ref=f"{held.grant_id}:{stamp}",
            subject_profile_id=held.profile_id,
            now=now,
        )
