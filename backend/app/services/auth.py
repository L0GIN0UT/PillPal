"""Account lifecycle: registration, verification, login, refresh rotation, codes, deletion.

Registration never reveals whether an e-mail is known: it always answers the
same and mails either a verification code (new address) or an "account
already exists" notice (known address). Verifying the code is the first
login. Codes are capped per account and purpose, and wrong guesses are
budgeted per account across codes, so requesting new codes does not buy new
guesses.
"""

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
from app.services.changes import lock_journal, record_change
from app.services.erasure import erase_account

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


def wrong_region() -> AppError:
    return AppError(409, "wrong_region", "This account belongs to another data region server")


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

    async def _user_by_email(self, email: str) -> User | None:
        return await self.session.scalar(
            select(User).where(func.lower(User.email) == email.lower())
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

    def _window_start(self) -> datetime:
        return _now() - timedelta(seconds=self.settings.email_code_window_seconds)

    async def _new_code_capped(self, user: User, purpose: EmailPurpose) -> str | None:
        """A fresh code, or ``None`` once the per-account cap for the window is reached."""
        # Lock the account row so concurrent requests cannot both pass the cap.
        await self.session.execute(select(User.id).where(User.id == user.id).with_for_update())
        issued = await self.session.scalar(
            select(func.count())
            .select_from(EmailCode)
            .where(
                EmailCode.user_id == user.id,
                EmailCode.purpose == purpose,
                EmailCode.created_at > self._window_start(),
            )
        )
        if (issued or 0) >= self.settings.email_code_daily_cap:
            _log.info("email_code_cap_reached", user_id=str(user.id), purpose=purpose)
            return None
        return await self._new_code(user, purpose)

    async def _send_code(self, user: User, purpose: EmailPurpose, code: str) -> None:
        try:
            await self.email_sender.send_code(
                to=user.email, user_id=user.id, purpose=purpose, code=code
            )
        except Exception as exc:
            # The user can request a new code; never fail the request on mail.
            _log.error("email_send_failed", purpose=purpose, exc_type=type(exc).__name__)

    async def _send_account_exists(self, user: User) -> None:
        try:
            await self.email_sender.send_account_exists(to=user.email, user_id=user.id)
        except Exception as exc:
            _log.error("email_send_failed", purpose="account_exists", exc_type=type(exc).__name__)

    async def _failed_attempts(self, user_id: uuid.UUID, purpose: EmailPurpose) -> int:
        total = await self.session.scalar(
            select(func.coalesce(func.sum(EmailCode.attempts), 0)).where(
                EmailCode.user_id == user_id,
                EmailCode.purpose == purpose,
                EmailCode.created_at > self._window_start(),
            )
        )
        return int(total or 0)

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
        if (
            row is None
            or row.attempts >= self.settings.email_code_max_attempts
            or await self._failed_attempts(user_id, purpose)
            >= self.settings.email_code_max_failed_per_window
        ):
            raise invalid_code()
        if not constant_time_equals(row.code_hash, self.tokens.code_hash(user_id, purpose, code)):
            row.attempts += 1
            await self.session.commit()
            raise invalid_code()
        row.consumed_at = _now()

    # -- public API --------------------------------------------------------

    async def register(self, req: RegisterRequest, device_id: str | None) -> None:
        if req.region != self.settings.region:
            raise wrong_region()
        # Hash first in every case so a known address does not answer faster.
        password_hash = await self.hasher.hash(req.password)
        existing = await self._user_by_email(req.email)
        if existing is not None:
            await self._send_account_exists(existing)
            return
        user = await self._create_user(req, password_hash, device_id)
        if user is None:  # lost a race against a concurrent registration
            existing = await self._user_by_email(req.email)
            if existing is not None:
                await self._send_account_exists(existing)
            return
        code = await self._new_code(user, "verify_email")
        await self.session.commit()
        _log.info("user_registered", user_id=str(user.id))
        await self._send_code(user, "verify_email", code)

    async def _create_user(
        self, req: RegisterRequest, password_hash: str, device_id: str | None
    ) -> User | None:
        """Unverified user plus its self profile; ``None`` if the e-mail got taken."""
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
            await self.session.rollback()
            return None
        await lock_journal(self.session, user.id)
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
        return user

    async def verify_email(self, email: str, code: str, device_id: str | None) -> TokenPair:
        """Consume the verification code and log in (first login after registration)."""
        user = await self._user_by_email(email)
        if user is None:
            raise invalid_code()
        await self._consume_code(user.id, "verify_email", code)
        user.email_verified_at = user.email_verified_at or _now()
        await touch_device(self.session, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device_id)
        await self.session.commit()
        _log.info("email_verified", user_id=str(user.id))
        return tokens

    async def resend_verification(self, email: str) -> None:
        user = await self._user_by_email(email)
        if user is None or user.email_verified_at is not None:
            return
        code = await self._new_code_capped(user, "verify_email")
        await self.session.commit()
        if code is not None:
            await self._send_code(user, "verify_email", code)

    async def login(self, email: str, password: str, device_id: str | None) -> TokenPair:
        user = await self._user_by_email(email)
        ok = await self.hasher.verify(user.password_hash if user else None, password)
        if user is None or not ok:
            _log.info("login_failed")
            raise invalid_credentials()
        if user.email_verified_at is None:
            # Only after a correct password, so it reveals nothing to a guesser.
            raise AppError(403, "email_not_verified", "Verify the e-mail address first")
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
        user = await self.session.scalar(select(User).where(User.id == row.user_id))
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

    async def request_password_reset(self, email: str) -> None:
        user = await self._user_by_email(email)
        if user is None:
            return
        code = await self._new_code_capped(user, "password_reset")
        await self.session.commit()
        if code is not None:
            await self._send_code(user, "password_reset", code)

    async def confirm_password_reset(self, email: str, code: str, new_password: str) -> None:
        user = await self._user_by_email(email)
        if user is None:
            raise invalid_code()
        await self._consume_code(user.id, "password_reset", code)
        user.password_hash = await self.hasher.hash(new_password)
        # Receiving the code proves control of the mailbox.
        user.email_verified_at = user.email_verified_at or _now()
        # Access tokens issued before this instant stop working (app.deps).
        user.password_changed_at = user.updated_at = _now()
        await self._revoke(RefreshToken.user_id == user.id)
        await self.session.commit()
        _log.info("password_reset", user_id=str(user.id))

    async def delete_account(self, user: User, password: str) -> None:
        """Erase the account and everything it owns, after re-checking the password."""
        if not await self.hasher.verify(user.password_hash, password):
            raise unauthorized("invalid_password", "Wrong password")
        user_id = user.id
        await erase_account(self.session, user_id)
        await self.session.commit()
        _log.info("account_deleted", user_id=str(user_id))
