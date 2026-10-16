"""E-mail codes and notices of the auth flows (issue, cap, consume, send)."""

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import EmailCode, User
from app.email import EmailPurpose, EmailSender, NoticeKind
from app.observability import get_logger
from app.security import TokenService, constant_time_equals, new_numeric_code
from app.services.account_deletion import lock_user
from app.services.auth_errors import invalid_code

_log = get_logger("pillpal.auth")


def _now() -> datetime:
    return datetime.now(UTC)


class AuthMail:
    """Mixin for :class:`app.services.auth.AuthService`; relies on its session and settings."""

    session: AsyncSession
    settings: Settings
    tokens: TokenService
    email_sender: EmailSender

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
        await lock_user(self.session, user.id)
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

    async def _send_notice(
        self, user: User, kind: NoticeKind, erase_after: datetime | None = None
    ) -> None:
        try:
            await self.email_sender.send_notice(
                to=user.email, user_id=user.id, kind=kind, erase_after=erase_after
            )
        except Exception as exc:
            _log.error("email_send_failed", purpose=kind, exc_type=type(exc).__name__)

    async def _send_known_address_notice(self, user: User) -> None:
        """Registration of an address that has an account: the notice fits its state."""
        if user.pending_deletion:  # instructions only: no ticket, no code, no link
            await self._send_notice(user, "account_pending_deletion", user.erase_after)
        else:
            await self._send_account_exists(user)

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
