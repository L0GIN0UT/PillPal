"""Account data export: request, status and the single download (ADR 0016 section 8).

The archive is built by the worker (``app.jobs.data_exports``). This module is the API side:

* :func:`request_export` - one export per session at a time, with a cooldown across sessions;
* :func:`claim_download` - **one atomic statement** turns a ``ready`` export into ``downloaded``
  and nulls the archive; two concurrent downloads cannot both win. The caller commits before it
  sends the bytes: a transfer that fails afterwards loses the export (the user asks again);
* :func:`explain_unavailable` - which refusal a failed claim deserves.

Nothing here logs a row's content, and the archive never leaves this module except as the
encrypted blob of the claim.
"""

from __future__ import annotations

import math
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import exists, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.exports import ACTIVE_EXPORT_STATUSES, DataExport
from app.db.models import RefreshToken
from app.errors import AppError, not_found, unauthorized
from app.services.users import lock_user

# The claim returns the *old* archive: a bare ``UPDATE ... SET archive = NULL RETURNING archive``
# would return NULL. The locking subquery is re-checked after a wait, so the loser of a race
# finds the row already ``downloaded``. The session must be live: a signed-out family cannot
# download with its still valid access token.
_CLAIM = text(
    """
    UPDATE data_exports AS d
    SET status = 'downloaded', archive = NULL
    FROM (
        SELECT x.id, x.archive
        FROM data_exports AS x
        WHERE x.id = :id AND x.user_id = :uid AND x.family_id = :sid
          AND x.status = 'ready' AND x.expires_at > :now
          AND EXISTS (
              SELECT 1 FROM refresh_tokens AS r
              WHERE r.family_id = :sid AND r.user_id = :uid AND r.revoked_at IS NULL
          )
        FOR UPDATE OF x
    ) AS old
    WHERE d.id = old.id
    RETURNING old.archive AS archive, d.ready_at AS ready_at
    """
)


def export_rate_limited(retry_after: int) -> AppError:
    return AppError(
        429,
        "export_rate_limited",
        "An export was requested recently, try again later",
        headers={"Retry-After": str(max(retry_after, 1))},
    )


def export_not_ready() -> AppError:
    return AppError(409, "export_not_ready", "The export is not ready yet")


def export_failed() -> AppError:
    return AppError(409, "export_failed", "The export failed, request a new one")


def export_gone() -> AppError:
    return AppError(410, "export_gone", "The export was downloaded or has expired")


def export_disabled() -> AppError:
    return AppError(403, "feature_disabled", "Data export is not enabled")


def _is_active(row: DataExport, now: datetime) -> bool:
    return row.status in ACTIVE_EXPORT_STATUSES and (
        row.status != "ready" or (row.expires_at is not None and row.expires_at > now)
    )


async def request_export(
    session: AsyncSession,
    settings: Settings,
    user_id: uuid.UUID,
    family_id: uuid.UUID,
    now: datetime,
) -> tuple[DataExport, bool]:
    """The export to answer with and whether it is new. The caller commits.

    The user row is locked, so two requests of one account are serialized: the second finds the
    first (replay) or the cooldown. An export of *another* session of the account does not
    count as a replay (that session could not download it): it falls under the cooldown.
    """
    user = await lock_user(session, user_id)
    if user is None or user.pending_deletion:
        raise unauthorized()
    own = (
        await session.scalars(
            select(DataExport)
            .where(
                DataExport.user_id == user_id,
                DataExport.family_id == family_id,
                DataExport.status.in_(ACTIVE_EXPORT_STATUSES),
            )
            .order_by(DataExport.requested_at.desc())
        )
    ).all()
    for row in own:
        if _is_active(row, now):
            return row, False
    cooldown = timedelta(seconds=settings.export_cooldown_seconds)
    latest = await session.scalar(
        select(func.max(DataExport.requested_at)).where(
            DataExport.user_id == user_id,
            DataExport.status != "downloaded",
            DataExport.requested_at > now - cooldown,
        )
    )
    if latest is not None:
        raise export_rate_limited(math.ceil((latest + cooldown - now).total_seconds()))
    row = DataExport(
        id=uuid.uuid4(), user_id=user_id, family_id=family_id, status="queued", requested_at=now
    )
    session.add(row)
    await session.flush()
    return row, True


async def get_export(session: AsyncSession, user_id: uuid.UUID, export_id: uuid.UUID) -> DataExport:
    """The caller's export; another account's id is missing like any unknown one."""
    row = await session.scalar(
        select(DataExport).where(DataExport.id == export_id, DataExport.user_id == user_id)
    )
    if row is None:
        raise not_found()
    return row


@dataclass(frozen=True)
class ClaimedArchive:
    export_id: uuid.UUID
    ready_at: datetime
    blob: bytes


async def claim_download(
    session: AsyncSession,
    user_id: uuid.UUID,
    export_id: uuid.UUID,
    family_id: uuid.UUID,
    now: datetime,
) -> ClaimedArchive | None:
    """Take the archive: ``None`` when this caller may not (see :func:`explain_unavailable`)."""
    result = await session.execute(
        _CLAIM, {"id": export_id, "uid": user_id, "sid": family_id, "now": now}
    )
    row = result.first()
    if row is None or row.archive is None or row.ready_at is None:
        return None
    return ClaimedArchive(export_id=export_id, ready_at=row.ready_at, blob=bytes(row.archive))


async def explain_unavailable(
    session: AsyncSession,
    user_id: uuid.UUID,
    export_id: uuid.UUID,
    family_id: uuid.UUID,
) -> AppError:
    """The refusal for a download that claimed nothing.

    404 for an unknown id, another account's export, another session's export and a signed-out
    session; then 409 while it is not ready or after it failed, and 410 once downloaded or
    expired.
    """
    row = await session.scalar(
        select(DataExport).where(DataExport.id == export_id, DataExport.user_id == user_id)
    )
    if row is None or row.family_id != family_id:
        return not_found()
    live = await session.scalar(
        select(
            exists().where(
                RefreshToken.family_id == family_id,
                RefreshToken.user_id == user_id,
                RefreshToken.revoked_at.is_(None),
            )
        )
    )
    if not live:
        return not_found()
    if row.status in ("queued", "running"):
        return export_not_ready()
    if row.status == "failed":
        return export_failed()
    return export_gone()


def archive_filename(region: str, ready_at: datetime) -> str:
    """``pillpal-export-<region>-<YYYYMMDD>.zip``, the date being the UTC day of ``ready_at``."""
    return f"pillpal-export-{region}-{ready_at.astimezone(UTC).strftime('%Y%m%d')}.zip"
