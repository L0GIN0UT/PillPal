"""Invites and grants: the REST surface of the relatives feature (ADR 0005, ADR 0009).

Owners create and revoke invites; anyone signed in can preview and accept one with
its token (a capability: the token travels in the body, never in a URL). Grants are
listed, changed field-by-field and deleted by the two parties of the link.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Response, status

from app.deps import CurrentUser, NowDep, SessionDep, SettingsDep, limit_by_user
from app.schemas.relatives import (
    GrantList,
    GrantPatch,
    IncomingGrantOut,
    InviteCreate,
    InviteCreated,
    InviteList,
    InviteOut,
    InvitePreview,
    InviteTokenRequest,
    OutgoingGrantOut,
)
from app.services import grants, invites

router = APIRouter(prefix="/v1", tags=["relatives"])

NO_CONTENT = status.HTTP_204_NO_CONTENT


@router.post(
    "/profiles/{profile_id}/invites",
    status_code=status.HTTP_201_CREATED,
    responses={
        409: {"description": "already_exists, too_many_invites"},
        422: {"description": "guardian invites need a managed profile"},
    },
)
async def create_invite(
    profile_id: uuid.UUID,
    body: InviteCreate,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    now: NowDep,
) -> InviteCreated:
    """Create an invite link. The token is part of ``url`` and is shown only here."""
    return await invites.create_invite(session, settings, now, user.id, profile_id, body)


@router.get("/profiles/{profile_id}/invites")
async def list_invites(
    profile_id: uuid.UUID,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    now: NowDep,
) -> InviteList:
    """Open (unused, unrevoked, unexpired) invites; never the token or the link."""
    rows = await invites.list_invites(session, settings, now, user.id, profile_id)
    return InviteList(items=[InviteOut.model_validate(r) for r in rows])


@router.delete(
    "/profiles/{profile_id}/invites/{invite_id}",
    status_code=NO_CONTENT,
    responses={409: {"description": "invite_used"}},
)
async def revoke_invite(
    profile_id: uuid.UUID, invite_id: uuid.UUID, user: CurrentUser, session: SessionDep, now: NowDep
) -> Response:
    await invites.revoke_invite(session, now, user.id, profile_id, invite_id)
    return Response(status_code=NO_CONTENT)


@router.post(
    "/invites/preview",
    dependencies=[Depends(limit_by_user("invite_preview"))],
    responses={
        404: {"description": "invite_invalid"},
        409: {"description": "invite_used, invite_own_profile"},
        410: {"description": "invite_expired"},
    },
)
async def preview_invite(
    body: InviteTokenRequest, user: CurrentUser, session: SessionDep, now: NowDep
) -> InvitePreview:
    """Who invites you to what; consumes nothing."""
    return await invites.preview_invite(session, now, user.id, body.token)


@router.post(
    "/invites/accept",
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(limit_by_user("invite_accept"))],
    responses={
        200: {"description": "Replay by the account that already accepted: the existing grant"},
        404: {"description": "invite_invalid"},
        409: {
            "description": "invite_used, invite_own_profile, already_linked, "
            "relatives_limit_reached, too_many_scopes"
        },
        410: {"description": "invite_expired"},
    },
)
async def accept_invite(
    body: InviteTokenRequest,
    response: Response,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    now: NowDep,
) -> IncomingGrantOut:
    """Accept explicitly; never called automatically by a link open."""
    grant, created = await invites.accept_invite(session, settings, now, user.id, body.token)
    if not created:
        response.status_code = status.HTTP_200_OK
    return grant


@router.get("/grants")
async def list_grants(user: CurrentUser, session: SessionDep, settings: SettingsDep) -> GrantList:
    """Grants on your profiles (``outgoing``) and grants you hold (``incoming``)."""
    return await grants.list_grants(session, settings, user.id)


@router.patch(
    "/grants/{grant_id}",
    responses={422: {"description": "Not exactly one field, or a field of the other party"}},
)
async def patch_grant(
    grant_id: uuid.UUID, body: GrantPatch, user: CurrentUser, session: SessionDep, now: NowDep
) -> IncomingGrantOut | OutgoingGrantOut:
    """The owner sets ``role``; the grantee sets ``notify_missed``. Never both."""
    return await grants.patch_grant(session, now, user.id, grant_id, body)


@router.delete("/grants/{grant_id}", status_code=NO_CONTENT)
async def delete_grant(grant_id: uuid.UUID, user: CurrentUser, session: SessionDep) -> Response:
    """Revoke (owner) or leave (grantee)."""
    await grants.delete_grant(session, user.id, grant_id)
    return Response(status_code=NO_CONTENT)
