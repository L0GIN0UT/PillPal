"""``/v1/me/identities``: the sign-in providers linked to the account (ADR 0017 section 6).

Link and unlink re-authenticate (the password, or a fresh assertion of an already linked provider)
and mail a notice that names the provider only; both end every other session of the account
(the caller's stays). The provider's subject is never returned. Listing and unlinking work with
``FEATURE_OAUTH`` off on purpose (a user can always see and remove a sign-in method); only
linking a new one needs the feature.
"""

from __future__ import annotations

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Response, status

from app.api.oauth import require_oauth
from app.api.reauth_dep import get_registry
from app.deps import (
    CurrentUser,
    EmailSenderDep,
    HasherDep,
    NowDep,
    RedisDep,
    SessionDep,
    SessionId,
    SettingsDep,
    TokensDep,
    limit_by_user,
    limit_reauth,
)
from app.oauth.registry import ProviderRegistry
from app.schemas.identities import IdentitiesOut, IdentityOut, LinkIdentityRequest
from app.schemas.reauth import ReauthProof
from app.services.identities import IdentityService

router = APIRouter(prefix="/v1/me/identities", tags=["me"])

_REFUSALS: dict[int | str, dict[str, Any]] = {
    401: {"description": "invalid_password, invalid_provider_token or invalid_token"},
    429: {"description": "rate_limited"},
    503: {"description": "provider_unreachable"},
}


def get_identity_service(
    session: SessionDep,
    settings: SettingsDep,
    tokens: TokensDep,
    hasher: HasherDep,
    email_sender: EmailSenderDep,
    redis: RedisDep,
    registry: Annotated[ProviderRegistry, Depends(get_registry)],
) -> IdentityService:
    return IdentityService(session, settings, tokens, hasher, email_sender, redis, registry)


Identities = Annotated[IdentityService, Depends(get_identity_service)]


@router.get("", dependencies=[Depends(limit_by_user("identity_list"))])
async def list_identities(user: CurrentUser, service: Identities) -> IdentitiesOut:
    """The linked providers (no provider subject)."""
    return IdentitiesOut(items=await service.list_identities(user))


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_oauth), Depends(limit_reauth("identity_link"))],
    responses={
        200: {"model": IdentityOut, "description": "Replay: the same identity, fresh assertion"},
        404: {"description": "provider not configured or not offered here"},
        409: {"description": "identity_in_use: linked to another account"},
        **_REFUSALS,
    },
)
async def link_identity(
    body: LinkIdentityRequest,
    user: CurrentUser,
    session_id: SessionId,
    service: Identities,
    now: NowDep,
    response: Response,
) -> IdentityOut:
    """Link a provider identity. Needs the re-authentication of the account (``password`` or
    ``reauth``) and a ``link`` nonce for the new assertion."""
    identity, created = await service.link(user, body, session_id, now)
    if not created:
        response.status_code = status.HTTP_200_OK
    return identity


@router.delete(
    "/{identity_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(limit_reauth("identity_unlink"))],
    responses={
        404: {"description": "unknown or foreign identity"},
        409: {"description": "last_sign_in_method"},
        **_REFUSALS,
    },
)
async def unlink_identity(
    identity_id: uuid.UUID,
    body: ReauthProof,
    user: CurrentUser,
    session_id: SessionId,
    service: Identities,
    now: NowDep,
) -> Response:
    """Unlink; the account must keep another way to sign in (a password counts only if set)."""
    await service.unlink(user, identity_id, body, session_id, now)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
