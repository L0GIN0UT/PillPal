"""``/v1/me/export``: request an account data export, poll it, download it once (ADR 0016 §8).

Behind ``FEATURE_DATA_EXPORT``. The request needs step-up re-authentication (the password; the
OAuth form arrives with milestone 5.7) and mails a notice without data. The download is a POST so
that the response is never cached or replayed from a history, and it needs the *same session* as
the request (the access token's ``sid``): the path id alone grants nothing.
"""

from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime

import anyio
from fastapi import APIRouter, Depends, Request, Response, status

from app.db.exports import DataExport
from app.deps import (
    CurrentUser,
    EmailSenderDep,
    HasherDep,
    NowDep,
    SessionDep,
    SessionId,
    SettingsDep,
)
from app.errors import AppError, unauthorized
from app.observability import get_logger
from app.ratelimit import RateLimiter, client_ip
from app.schemas.exports import ExportOut, ExportRequest
from app.services.data_encryption import EXPORT_PURPOSE, DataKeyring, DecryptionError
from app.services.exports import (
    archive_filename,
    claim_download,
    explain_unavailable,
    export_disabled,
    get_export,
    request_export,
)

_log = get_logger("pillpal.export")

router = APIRouter(prefix="/v1/me/export", tags=["me"])

NO_STORE = "private, no-store"


async def require_export_enabled(settings: SettingsDep) -> None:
    if not settings.feature_data_export:
        raise export_disabled()


def _limit(scope: str, limit_of: Callable[..., int] | None) -> Callable[..., Awaitable[None]]:
    """Per user across IPs. ``None``: the auth limits (the request is a password check)."""

    async def dependency(request: Request, user: CurrentUser, settings: SettingsDep) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        await limiter.check(
            scope,
            client_ip(request),
            str(user.id),
            per_account=True,
            limit=limit_of(settings) if limit_of else None,
            window=settings.export_rate_window_seconds if limit_of else None,
        )

    return dependency


limit_request = _limit("export_request", None)
limit_status = _limit("export_status", lambda s: s.export_status_rate_limit)
limit_download = _limit("export_download", lambda s: s.export_download_rate_limit)


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
        401: {"description": "reauth_required, invalid_password or invalid_token"},
        403: {"description": "feature_disabled"},
        429: {"description": "export_rate_limited (Retry-After) or rate_limited"},
    },
)
async def post_export(
    user: CurrentUser,
    session_id: SessionId,
    session: SessionDep,
    settings: SettingsDep,
    hasher: HasherDep,
    email_sender: EmailSenderDep,
    now: NowDep,
    response: Response,
    body: ExportRequest | None = None,
) -> ExportOut:
    """Ask for an export of the account; the worker builds it within a minute or so."""
    password = body.password if body is not None else None
    if password is None:
        raise unauthorized("reauth_required", "Re-enter your password")
    if not await hasher.verify(user.password_hash, password):
        raise unauthorized("invalid_password", "Wrong password")
    row, created = await request_export(session, settings, user.id, session_id, now)
    out = export_out(row, now)
    await session.commit()
    response.headers["Cache-Control"] = NO_STORE
    if not created:
        response.status_code = status.HTTP_200_OK
        return out
    try:
        await email_sender.send_notice(to=user.email, user_id=user.id, kind="export_requested")
    except Exception as exc:  # never fail the request on mail
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
    row = await get_export(session, user.id, export_id)
    response.headers["Cache-Control"] = NO_STORE
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
    },
)
async def download_export(
    export_id: uuid.UUID,
    user: CurrentUser,
    session_id: SessionId,
    session: SessionDep,
    settings: SettingsDep,
    now: NowDep,
) -> Response:
    """The zip archive. Exactly one call succeeds; the claim commits before the bytes are sent."""
    claimed = await claim_download(session, user.id, export_id, session_id, now)
    if claimed is None:
        raise await explain_unavailable(session, user.id, export_id, session_id)
    await session.commit()
    keyring = DataKeyring.from_settings(settings)
    try:
        if keyring is None:
            raise DecryptionError
        archive = await anyio.to_thread.run_sync(
            keyring.decrypt, EXPORT_PURPOSE, claimed.export_id, claimed.blob
        )
    except DecryptionError:
        # A key left the ring too early or the row was tampered with: the export is lost.
        _log.error("export_decrypt_failed", export_id=str(export_id))
        raise AppError(500, "export_unavailable", "The export could not be read") from None
    return Response(
        content=archive,
        media_type="application/zip",
        headers={
            "Content-Disposition": (
                f'attachment; filename="{archive_filename(settings.region, claimed.ready_at)}"'
            ),
            "Cache-Control": "no-store",
        },
    )
