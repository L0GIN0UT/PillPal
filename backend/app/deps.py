"""FastAPI dependencies: settings, DB session, current user, device id."""

from __future__ import annotations

from collections.abc import AsyncIterator, Awaitable, Callable
from datetime import UTC, datetime
from typing import Annotated

from fastapi import Depends, Header, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings
from app.db.models import User
from app.email import EmailSender
from app.errors import unauthorized
from app.ratelimit import RateLimiter, client_ip
from app.security import PasswordHasher, TokenService
from app.services.changes import lock_journal
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


def get_now() -> datetime:
    """The clock of endpoints with time rules; tests override it instead of sleeping."""
    return datetime.now(UTC)


SessionDep = Annotated[AsyncSession, Depends(get_session)]
NowDep = Annotated[datetime, Depends(get_now)]
SettingsDep = Annotated[Settings, Depends(get_settings)]
TokensDep = Annotated[TokenService, Depends(get_tokens)]
HasherDep = Annotated[PasswordHasher, Depends(get_hasher)]
EmailSenderDep = Annotated[EmailSender, Depends(get_email_sender)]

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
    changed = user.password_changed_at
    # ``iat`` has whole-second precision: a token from the same second survives.
    if changed is not None and claims.issued_at < int(changed.timestamp()):
        raise unauthorized()
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


async def lock_user_journal(user: CurrentUser, session: SessionDep) -> None:
    """Route dependency for writes that journal: see ``app.services.changes``."""
    await lock_journal(session, user.id)


JournalLock = Depends(lock_user_journal)


def limit_by_user(scope: str) -> Callable[..., Awaitable[None]]:
    """Dependency factory: rate limit an authenticated endpoint per user."""

    async def dependency(request: Request, user: CurrentUser) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        await limiter.check(scope, client_ip(request), str(user.id), per_account=True)

    return dependency
