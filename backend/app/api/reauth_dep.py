"""Dependencies for the routes that re-authenticate (ADR 0017 section 8)."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Request

from app.deps import HasherDep, RedisDep, SessionDep, SettingsDep
from app.oauth.registry import ProviderRegistry
from app.services.oauth_state import OAuthState
from app.services.reauth import Reauthenticator


def get_registry(request: Request) -> ProviderRegistry:
    registry: ProviderRegistry = request.app.state.oauth_providers
    return registry


def get_reauthenticator(
    session: SessionDep,
    settings: SettingsDep,
    hasher: HasherDep,
    redis: RedisDep,
    registry: Annotated[ProviderRegistry, Depends(get_registry)],
) -> Reauthenticator:
    return Reauthenticator(session, settings, hasher, OAuthState(redis, settings), registry)


Reauth = Annotated[Reauthenticator, Depends(get_reauthenticator)]
