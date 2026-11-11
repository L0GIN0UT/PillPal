"""The mail job of the enumeration-sensitive endpoints (mixin of ``AuthService``).

See ``app.services.auth_mail_job`` for why this runs after the response.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from sqlalchemy import select

from app.db.models import User
from app.domain.passwords import has_usable_password
from app.errors import AppError
from app.observability import get_logger
from app.services.accounts import create_account
from app.services.auth_mail import AuthMail, _now
from app.services.auth_mail_job import MailJob, RegisterPayload
from app.services.oauth_state import OAuthState

_log = get_logger("pillpal.auth")


class AuthMailDelivery(AuthMail):
    oauth_state: OAuthState

    if TYPE_CHECKING:

        async def _user_by_email(self, email: str) -> User | None: ...

    async def deliver_mail(self, job: MailJob) -> None:
        """Conditions are re-read here, not trusted from the request."""
        if job.kind == "register" and job.register is not None:
            await self._deliver_register(job.register)
            return
        user = await self.session.scalar(select(User).where(User.id == job.user_id))
        if user is None:
            return
        if job.kind == "known_address_notice":
            await self._send_known_address_notice(user)
        elif job.purpose is not None:
            await self._deliver_code(user, job)

    async def _deliver_code(self, user: User, job: MailJob) -> None:
        purpose = job.purpose
        if purpose is None or (purpose == "verify_email" and user.email_verified_at is not None):
            return
        code = await self._new_code_capped(user, purpose)
        await self.session.commit()
        if code is not None:
            await self._send_code(user, purpose, code)
        if purpose == "verify_email":
            await self._warn_if_oauth_pending(user)

    async def _deliver_register(self, req: RegisterPayload) -> None:
        """A new address gets an unverified account and a code, a known one a notice."""
        existing = await self._user_by_email(req.email)
        if existing is None:
            user = await create_account(
                self.session,
                self.settings,
                email=req.email,
                password_hash=req.password_hash,
                locale=req.locale,
                timezone=req.timezone,
                display_name=req.display_name,
                consents=req.consents,
                consent_source="registration",
                device_id=req.device_id,
                now=_now(),
            )
            if user is not None:
                user_id = user.id
                code = await self._new_code(user, "verify_email")
                await self.session.commit()
                _log.info("user_registered", user_id=str(user_id))
                await self._send_code(user, "verify_email", code)
                return
            # Lost a race against a concurrent registration: that address is known now.
            existing = await self._user_by_email(req.email)
        if existing is not None:
            await self._send_known_address_notice(existing)

    async def _warn_if_oauth_pending(self, user: User) -> None:
        """A resent code for an OAuth sign-up in progress also carries the "not linked" notice:
        whoever holds the mailbox sees that the sign-up was started with a provider. Best effort
        (Redis down: no notice; the code still works and links nothing without the token)."""
        if has_usable_password(user.password_hash):
            return
        try:
            pending = await self.oauth_state.has_pending(user.id)
        except AppError:
            return
        if pending:
            await self._send_notice(user, "oauth_not_linked")
