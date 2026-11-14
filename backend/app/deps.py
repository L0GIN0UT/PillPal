"""FastAPI dependencies: settings, DB session, current user, device id."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from datetime import UTC, datetime
from typing import Annotated

from fastapi import Depends, Header, Request
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings
from app.db.models import User
from app.email import EmailSender
from app.errors import unauthorized
from app.ratelimit import RateLimiter, client_ip
from app.security import AccessClaims, PasswordHasher, TokenService
from app.services.changes import lock_journal
from app.services.scopes import (
    ScopeLock,
    lock_for_medication,
    lock_for_profile,
    lock_for_schedule,
)
from app.validators import DEVICE_ID_PATTERN


def get_settings(request: Request) -> Settings:
    settings: Settings = request.app.state.settings
    return settings


def get_sessionmaker(request: Request) -> async_sessionmaker[AsyncSession]:
    maker: async_sessionmaker[AsyncSession] = request.app.state.sessionmaker
    return maker


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    maker = get_sessionmaker(request)
    async with maker() as session:
        yield session


def get_tokens(request: Request) -> TokenService:
    tokens: TokenService = request.app.state.tokens
    return tokens


def get_hasher(request: Request) -> PasswordHasher:
    hasher: PasswordHasher = request.app.state.hasher
    return hasher


def get_email_sender(request: Request) -> EmailSender:
    sender: EmailSender = request.app.state.email_sender
    return sender


def get_redis(request: Request) -> Redis:
    redis: Redis = request.app.state.redis
    return redis


def get_now() -> datetime:
    """The clock of endpoints with time rules; tests override it instead of sleeping."""
    return datetime.now(UTC)


SessionDep = Annotated[AsyncSession, Depends(get_session)]
SessionmakerDep = Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)]
NowDep = Annotated[datetime, Depends(get_now)]
SettingsDep = Annotated[Settings, Depends(get_settings)]
TokensDep = Annotated[TokenService, Depends(get_tokens)]
HasherDep = Annotated[PasswordHasher, Depends(get_hasher)]
EmailSenderDep = Annotated[EmailSender, Depends(get_email_sender)]
RedisDep = Annotated[Redis, Depends(get_redis)]

OptionalDeviceId = Annotated[
    str | None,
    Header(alias="X-Device-ID", pattern=DEVICE_ID_PATTERN, description="Stable client device id"),
]
RequiredDeviceId = Annotated[
    str,
    Header(alias="X-Device-ID", pattern=DEVICE_ID_PATTERN, description="Stable client device id"),
]


def get_access_claims(request: Request, tokens: TokensDep) -> AccessClaims:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise unauthorized()
    claims = tokens.decode_access(token.strip())
    if claims is None:
        raise unauthorized()
    return claims


ClaimsDep = Annotated[AccessClaims, Depends(get_access_claims)]


async def get_current_user(claims: ClaimsDep, session: SessionDep) -> User:
    user = await session.scalar(select(User).where(User.id == claims.user_id))
    if user is None:
        raise unauthorized()
    # Order matters. Pending first: it is exact and needs no timestamp, and it kills every token
    # from the request until the restore. ``tokens_not_before`` then kills the ones issued before
    # the request or the restore, but only to whole seconds (``iat`` has no finer precision):
    # a token minted in the same second as the cutoff survives. Nothing relevant is minted in
    # that second: the request revokes the sessions and the restore issues the fresh pair.
    if user.pending_deletion:
        raise unauthorized()
    # A password change refuses the whole second it happened in (``<=``): a token an attacker got
    # in that second must not survive. Tokens are minted after it (``wait_past_password_change``).
    changed = user.password_changed_at
    if changed is not None and claims.issued_at <= int(changed.timestamp()):
        raise unauthorized()
    cutoff = user.tokens_not_before
    if cutoff is not None and claims.issued_at < int(cutoff.timestamp()):
        raise unauthorized()
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


def get_session_id(claims: ClaimsDep) -> uuid.UUID:
    """The session (refresh family) of the access token; tokens without ``sid`` are refused, the
    app signs in again (ADR 0016 section 8)."""
    if claims.session_id is None:
        raise unauthorized("invalid_token", "Sign in again")
    return claims.session_id


SessionId = Annotated[uuid.UUID, Depends(get_session_id)]


async def lock_own_scope(user: CurrentUser, session: SessionDep) -> None:
    """Writes that create in the caller's own scope (a new managed profile)."""
    await lock_journal(session, [user.id])


async def lock_profile_scope(
    profile_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> ScopeLock:
    """REST writes under ``/profiles/{profile_id}``: lock its owner; 404 unless full access."""
    return await lock_for_profile(session, user.id, profile_id)


async def lock_profile_scope_for_purge(
    profile_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> ScopeLock:
    """``DELETE /profiles/{id}``: like :func:`lock_profile_scope`, but an archive may be locked
    (deleting it is a purge, allowed to its owner and guardians once the former owner is erased)."""
    return await lock_for_profile(session, user.id, profile_id, allow_archived=True)


async def lock_medication_scope(
    medication_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> ScopeLock:
    return await lock_for_medication(session, user.id, medication_id)


async def lock_schedule_scope(
    schedule_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> ScopeLock:
    return await lock_for_schedule(session, user.id, schedule_id)


OwnScopeLock = Depends(lock_own_scope)
ProfileScopeLock = Depends(lock_profile_scope)
MedicationScopeLock = Depends(lock_medication_scope)
ProfileScope = Annotated[ScopeLock, Depends(lock_profile_scope)]
ProfilePurgeScope = Annotated[ScopeLock, Depends(lock_profile_scope_for_purge)]
MedicationScope = Annotated[ScopeLock, Depends(lock_medication_scope)]
ScheduleScope = Annotated[ScopeLock, Depends(lock_schedule_scope)]


def limit_reauth(scope: str) -> Callable[..., Awaitable[None]]:
    """Dependency factory for routes that re-authenticate (ADR 0017 section 8).

    The password check shares the ``login`` bucket of the account, so guessing it through
    deletion, export, link or unlink spends the same budget as ``POST /v1/auth/login``; then the
    route's own scope. Both fail closed: with Redis down the request is refused (503), because the
    limiter is the only brake on guessing here.
    """

    async def dependency(request: Request, user: CurrentUser) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        ip = client_ip(request)
        await limiter.check(
            "login", ip, user.email.strip().lower()[:320], per_account=True, fail_closed=True
        )
        await limiter.check(scope, ip, str(user.id), per_account=True, fail_closed=True)

    return dependency


def limit_by_user(
    scope: str, attempts: Callable[[Settings], int] | None = None
) -> Callable[..., Awaitable[None]]:
    """Dependency factory: rate limit an authenticated endpoint per user.

    ``attempts`` picks the scope's own budget from the settings (same window as the auth limits);
    without it the auth default applies.
    """

    async def dependency(request: Request, user: CurrentUser) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        settings: Settings = request.app.state.settings
        limit = attempts(settings) if attempts is not None else None
        await limiter.check(scope, client_ip(request), str(user.id), per_account=True, limit=limit)

    return dependency
