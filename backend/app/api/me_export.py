"""``/v1/me/export``: request an account data export, poll it, download it once (ADR 0016 §8).

Behind ``FEATURE_DATA_EXPORT``. The request needs step-up re-authentication (the password, a
required field like ``DELETE /v1/me``, or a fresh assertion of a linked sign-in provider, ADR 0017
section 8) and mails a notice without data. The download is a POST so that the response is never
cached or replayed from a history, and it needs the *same session* as the request (the access
token's ``sid``): the path id alone grants nothing.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import Awaitable, Callable, Iterator
from contextlib import contextmanager
from datetime import datetime

from fastapi import APIRouter, Depends, Request, Response, status
from starlette.concurrency import run_in_threadpool

from app.api.reauth_dep import Reauth
from app.config import Settings
from app.db.exports import DataExport
from app.deps import (
    CurrentUser,
    EmailSenderDep,
    NowDep,
    SessionDep,
    SessionId,
    SettingsDep,
    limit_reauth,
)
from app.errors import AppError
from app.observability import get_logger
from app.ratelimit import RateLimiter, client_ip
from app.schemas.exports import ExportOut, ExportRequest
from app.services.data_encryption import EXPORT_PURPOSE, DataKeyring, DecryptionError
from app.services.exports import (
    archive_filename,
    claim_download,
    explain_unavailable,
    export_busy,
    export_disabled,
    get_export,
    request_export,
)

_log = get_logger("pillpal.export")

router = APIRouter(prefix="/v1/me/export", tags=["me"])

NO_STORE = "private, no-store"
# On every answer of the status and download routes, errors included.
SAFE_HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"}


async def require_export_enabled(settings: SettingsDep) -> None:
    if not settings.feature_data_export:
        raise export_disabled()


def _limit(
    scope: str, limit_of: Callable[[Settings], int], *, fail_closed: bool = False
) -> Callable[..., Awaitable[None]]:
    """Per user across IPs, with the export rate window. ``fail_closed``: with Redis down the
    call is refused instead of unthrottled."""

    async def dependency(request: Request, user: CurrentUser, settings: SettingsDep) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        await limiter.check(
            scope,
            client_ip(request),
            str(user.id),
            per_account=True,
            limit=limit_of(settings),
            window=settings.export_rate_window_seconds,
            fail_closed=fail_closed,
        )

    return dependency


# The request is a re-auth: its password check shares the login budget (``limit_reauth``).
limit_request = limit_reauth("export_request")
limit_status = _limit("export_status", lambda s: s.export_status_rate_limit)
limit_download = _limit("export_download", lambda s: s.export_download_rate_limit, fail_closed=True)


@contextmanager
def safe_errors() -> Iterator[None]:
    """Refusals carry ``no-store`` and ``nosniff`` like the archive itself."""
    try:
        yield
    except AppError as exc:
        exc.headers = {**(exc.headers or {}), **SAFE_HEADERS}
        raise


def export_out(row: DataExport, now: datetime) -> ExportOut:
    """A ``ready`` export past its expiry reads as ``expired`` before the cron marks it."""
    out = ExportOut.model_validate(row, from_attributes=True)
    if row.status == "ready" and row.expires_at is not None and row.expires_at <= now:
        out.status = "expired"
    return out


@router.post(
    "",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[Depends(require_export_enabled), Depends(limit_request)],
    responses={
        200: {"model": ExportOut, "description": "An export of this session is already active"},
        401: {"description": "invalid_password or invalid_token"},
        403: {"description": "feature_disabled"},
        429: {"description": "export_rate_limited (Retry-After) or rate_limited"},
        503: {"description": "rate_limit_unavailable"},
    },
)
async def post_export(
    body: ExportRequest,
    user: CurrentUser,
    session_id: SessionId,
    session: SessionDep,
    settings: SettingsDep,
    reauth: Reauth,
    email_sender: EmailSenderDep,
    now: NowDep,
    response: Response,
) -> ExportOut:
    """Ask for an export of the account; the worker builds it within a minute or so."""
    await reauth.check(user, body, now)
    row, created = await request_export(session, settings, user.id, session_id, now)
    out = export_out(row, now)
    await session.commit()
    response.headers["Cache-Control"] = NO_STORE
    if not created:
        response.status_code = status.HTTP_200_OK
        return out
    try:
        await email_sender.send_notice(to=user.email, user_id=user.id, kind="export_requested")
    except Exception as exc:
        # Deliberately broad: the export is already queued, a mail provider failure of any kind
        # must not turn it into an error (the type is logged, never the address).
        _log.error("email_send_failed", purpose="export_requested", exc_type=type(exc).__name__)
    _log.info("export_requested", user_id=str(user.id), export_id=str(row.id))
    return out


@router.get(
    "/{export_id}",
    dependencies=[Depends(require_export_enabled), Depends(limit_status)],
)
async def get_export_status(
    export_id: uuid.UUID,
    user: CurrentUser,
    session: SessionDep,
    now: NowDep,
    response: Response,
) -> ExportOut:
    with safe_errors():
        row = await get_export(session, user.id, export_id)
    response.headers.update(SAFE_HEADERS)
    return export_out(row, now)


@router.post(
    "/{export_id}/download",
    dependencies=[Depends(require_export_enabled), Depends(limit_download)],
    response_class=Response,
    responses={
        200: {"content": {"application/zip": {}}, "description": "The archive, once"},
        404: {"description": "Unknown, another account's or another session's export"},
        409: {"description": "export_not_ready or export_failed"},
        410: {"description": "export_gone: downloaded or expired"},
        503: {"description": "export_busy or rate_limit_unavailable"},
    },
)
async def download_export(
    export_id: uuid.UUID,
    request: Request,
    user: CurrentUser,
    session_id: SessionId,
    session: SessionDep,
    settings: SettingsDep,
    now: NowDep,
) -> Response:
    """The zip archive. Exactly one call succeeds; the claim commits before the bytes are sent."""
    slots: asyncio.Semaphore = request.app.state.export_download_slots
    with safe_errors():
        if slots.locked():  # each download holds an archive in memory: shed load, keep the export
            raise export_busy()
        async with slots:
            archive, filename = await _claim_and_open(
                session, settings, user.id, export_id, session_id, now
            )
    return Response(
        content=archive,
        media_type="application/zip",
        headers={**SAFE_HEADERS, "Content-Disposition": f'attachment; filename="{filename}"'},
    )


async def _claim_and_open(
    session: SessionDep,
    settings: Settings,
    user_id: uuid.UUID,
    export_id: uuid.UUID,
    session_id: uuid.UUID,
    now: datetime,
) -> tuple[bytes, str]:
    claimed = await claim_download(session, user_id, export_id, session_id, now)
    if claimed is None:
        raise await explain_unavailable(session, user_id, export_id, session_id, now)
    keyring = DataKeyring.from_settings(settings)
    if keyring is None or not keyring.can_decrypt(claimed.blob):
        # The key is gone: keep the export (roll the claim back) instead of losing it.
        await session.rollback()
        _log.error("export_key_unavailable", export_id=str(export_id))
        raise AppError(500, "export_unavailable", "The export could not be read")
    await session.commit()
    try:
        archive = await run_in_threadpool(
            keyring.decrypt, EXPORT_PURPOSE, claimed.export_id, claimed.blob
        )
    except DecryptionError:
        # A tampered or moved blob: the claim is committed, the export is lost.
        _log.error("export_decrypt_failed", export_id=str(export_id))
        raise AppError(500, "export_unavailable", "The export could not be read") from None
    return archive, archive_filename(settings.region, claimed.ready_at)
