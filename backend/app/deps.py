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
from app.security import PasswordHasher, TokenService
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


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    maker: async_sessionmaker[AsyncSession] = request.app.state.sessionmaker
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


async def get_current_user(request: Request, session: SessionDep, tokens: TokensDep) -> User:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise unauthorized()
    claims = tokens.decode_access(token.strip())
    if claims is None:
        raise unauthorized()
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
    for cutoff in (user.password_changed_at, user.tokens_not_before):
        if cutoff is not None and claims.issued_at < int(cutoff.timestamp()):
            raise unauthorized()
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


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


def limit_by_user(scope: str) -> Callable[..., Awaitable[None]]:
    """Dependency factory: rate limit an authenticated endpoint per user."""

    async def dependency(request: Request, user: CurrentUser) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        await limiter.check(scope, client_ip(request), str(user.id), per_account=True)

    return dependency
