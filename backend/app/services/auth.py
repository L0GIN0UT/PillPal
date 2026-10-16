"""Account lifecycle: registration, login, refresh rotation, codes, deletion."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql.elements import ColumnElement

from app.config import Settings
from app.db.models import Device, EmailCode, Profile, RefreshToken, User
from app.email import EmailPurpose, EmailSender
from app.errors import AppError, unauthorized
from app.observability import get_logger
from app.schemas.auth import RegisterRequest, TokenPair
from app.security import (
    PasswordHasher,
    TokenService,
    constant_time_equals,
    hash_refresh_token,
    new_numeric_code,
    new_refresh_token,
)
from app.services.changes import record_change

_log = get_logger("pillpal.auth")

DEFAULT_SELF_DISPLAY_NAME = "Me"


def _now() -> datetime:
    return datetime.now(UTC)


def invalid_credentials() -> AppError:
    return unauthorized("invalid_credentials", "Invalid e-mail or password")


def invalid_token() -> AppError:
    return unauthorized("invalid_token", "Invalid or expired refresh token")


def invalid_code() -> AppError:
    return AppError(400, "invalid_code", "Invalid or expired code")


async def touch_device(session: AsyncSession, user_id: uuid.UUID, device_id: str | None) -> None:
    if device_id is None:
        return
    stmt = pg_insert(Device).values(id=uuid.uuid4(), user_id=user_id, device_id=device_id)
    await session.execute(
        stmt.on_conflict_do_update(
            index_elements=[Device.user_id, Device.device_id],
            set_={"last_seen_at": func.now()},
        )
    )


class AuthService:
    def __init__(
        self,
        session: AsyncSession,
        settings: Settings,
        tokens: TokenService,
        hasher: PasswordHasher,
        email_sender: EmailSender,
    ) -> None:
        self.session = session
        self.settings = settings
        self.tokens = tokens
        self.hasher = hasher
        self.email_sender = email_sender

    # -- lookups -----------------------------------------------------------

    async def _active_user_by_email(self, email: str) -> User | None:
        return await self.session.scalar(
            select(User).where(func.lower(User.email) == email.lower(), User.deleted_at.is_(None))
        )

    # -- tokens ------------------------------------------------------------

    async def _issue_tokens(
        self, user_id: uuid.UUID, device_id: str | None, family_id: uuid.UUID | None = None
    ) -> TokenPair:
        refresh = new_refresh_token()
        self.session.add(
            RefreshToken(
                id=uuid.uuid4(),
                user_id=user_id,
                family_id=family_id or uuid.uuid4(),
                token_hash=hash_refresh_token(refresh),
                device_id=device_id,
                expires_at=_now() + timedelta(seconds=self.settings.refresh_token_ttl_seconds),
            )
        )
        return TokenPair(
            access_token=self.tokens.issue_access(user_id),
            refresh_token=refresh,
            expires_in=self.tokens.access_ttl,
        )

    async def _revoke(self, condition: ColumnElement[bool]) -> None:
        await self.session.execute(
            update(RefreshToken)
            .where(condition, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=func.now())
        )

    # -- codes -------------------------------------------------------------

    async def _new_code(self, user: User, purpose: EmailPurpose) -> str:
        # A fresh code invalidates any previous one of the same purpose.
        await self.session.execute(
            update(EmailCode)
            .where(
                EmailCode.user_id == user.id,
                EmailCode.purpose == purpose,
                EmailCode.consumed_at.is_(None),
            )
            .values(consumed_at=func.now())
        )
        code = new_numeric_code()
        self.session.add(
            EmailCode(
                id=uuid.uuid4(),
                user_id=user.id,
                purpose=purpose,
                code_hash=self.tokens.code_hash(user.id, purpose, code),
                expires_at=_now() + timedelta(seconds=self.settings.email_code_ttl_seconds),
            )
        )
        return code

    async def _send(self, to: str, purpose: EmailPurpose, code: str) -> None:
        try:
            await self.email_sender.send_code(to=to, purpose=purpose, code=code)
        except Exception as exc:
            # The user can request a new code; never fail the request on mail.
            _log.error("email_send_failed", purpose=purpose, exc_type=type(exc).__name__)

    async def _consume_code(self, user_id: uuid.UUID, purpose: EmailPurpose, code: str) -> None:
        """Validate and consume the active code; commits failed attempts."""
        row = await self.session.scalar(
            select(EmailCode)
            .where(
                EmailCode.user_id == user_id,
                EmailCode.purpose == purpose,
                EmailCode.consumed_at.is_(None),
                EmailCode.expires_at > func.now(),
            )
            .order_by(EmailCode.created_at.desc())
            .limit(1)
            .with_for_update()
        )
        if row is None or row.attempts >= self.settings.email_code_max_attempts:
            raise invalid_code()
        if not constant_time_equals(row.code_hash, self.tokens.code_hash(user_id, purpose, code)):
            row.attempts += 1
            await self.session.commit()
            raise invalid_code()
        row.consumed_at = _now()

    # -- public API --------------------------------------------------------

    async def register(self, req: RegisterRequest, device_id: str | None) -> tuple[User, TokenPair]:
        if req.region != self.settings.region:
            raise AppError(
                409, "wrong_region", "This account belongs to another data region server"
            )
        email_taken = AppError(409, "email_taken", "An account with this e-mail already exists")
        if await self._active_user_by_email(req.email) is not None:
            raise email_taken
        password_hash = await self.hasher.hash(req.password)
        now = _now()
        user = User(
            id=uuid.uuid4(),
            email=req.email,
            password_hash=password_hash,
            region=self.settings.region,
            locale=req.locale,
            created_at=now,
            updated_at=now,
        )
        self.session.add(user)
        try:
            await self.session.flush()
        except IntegrityError:
            # Lost a race against a concurrent registration with the same e-mail.
            await self.session.rollback()
            raise email_taken from None
        profile = Profile(
            id=uuid.uuid4(),
            owner_user_id=user.id,
            kind="self",
            display_name=req.display_name or DEFAULT_SELF_DISPLAY_NAME,
            timezone=req.timezone,
            version=1,
            client_updated_at=now,
            updated_by_device=device_id or "",
        )
        self.session.add(profile)
        await self.session.flush()
        await record_change(self.session, user.id, "profile", profile.id, "upsert")
        await touch_device(self.session, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device_id)
        code = await self._new_code(user, "verify_email")
        await self.session.commit()
        _log.info("user_registered", user_id=str(user.id))
        await self._send(user.email, "verify_email", code)
        return user, tokens

    async def login(self, email: str, password: str, device_id: str | None) -> TokenPair:
        user = await self._active_user_by_email(email)
        ok = await self.hasher.verify(user.password_hash if user else None, password)
        if user is None or not ok:
            _log.info("login_failed")
            raise invalid_credentials()
        if self.hasher.needs_rehash(user.password_hash):
            user.password_hash = await self.hasher.hash(password)
        await touch_device(self.session, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device_id)
        await self.session.commit()
        _log.info("login_succeeded", user_id=str(user.id))
        return tokens

    async def refresh(self, token: str, device_id: str | None) -> TokenPair:
        row = await self.session.scalar(
            select(RefreshToken)
            .where(RefreshToken.token_hash == hash_refresh_token(token))
            .with_for_update()
        )
        if row is None:
            raise invalid_token()
        if row.used_at is not None:
            # A rotated token came back: assume theft and kill the whole family.
            await self._revoke(RefreshToken.family_id == row.family_id)
            await self.session.commit()
            _log.warning("refresh_token_reuse_detected", user_id=str(row.user_id))
            raise unauthorized("token_reused", "Refresh token reuse detected; session revoked")
        if row.revoked_at is not None or row.expires_at <= _now():
            raise invalid_token()
        user = await self.session.scalar(
            select(User).where(User.id == row.user_id, User.deleted_at.is_(None))
        )
        if user is None:
            raise invalid_token()
        row.used_at = _now()
        device = device_id or row.device_id
        await touch_device(self.session, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device, family_id=row.family_id)
        await self.session.commit()
        return tokens

    async def logout(self, token: str) -> None:
        row = await self.session.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(token))
        )
        if row is not None:
            await self._revoke(RefreshToken.family_id == row.family_id)
            await self.session.commit()

    async def resend_verification(self, user: User) -> None:
        if user.email_verified_at is not None:
            return
        code = await self._new_code(user, "verify_email")
        await self.session.commit()
        await self._send(user.email, "verify_email", code)

    async def verify_email(self, user: User, code: str) -> None:
        await self._consume_code(user.id, "verify_email", code)
        user.email_verified_at = user.email_verified_at or _now()
        await self.session.commit()

    async def request_password_reset(self, email: str) -> None:
        user = await self._active_user_by_email(email)
        if user is None:
            return
        code = await self._new_code(user, "password_reset")
        await self.session.commit()
        await self._send(user.email, "password_reset", code)

    async def confirm_password_reset(self, email: str, code: str, new_password: str) -> None:
        user = await self._active_user_by_email(email)
        if user is None:
            raise invalid_code()
        await self._consume_code(user.id, "password_reset", code)
        user.password_hash = await self.hasher.hash(new_password)
        # Receiving the code proves control of the mailbox.
        user.email_verified_at = user.email_verified_at or _now()
        user.updated_at = _now()
        await self._revoke(RefreshToken.user_id == user.id)
        await self.session.commit()
        _log.info("password_reset", user_id=str(user.id))

    async def delete_account(self, user: User) -> None:
        user.deleted_at = _now()
        user.updated_at = _now()
        await self._revoke(RefreshToken.user_id == user.id)
        await self.session.commit()
        _log.info("account_deleted", user_id=str(user.id))
