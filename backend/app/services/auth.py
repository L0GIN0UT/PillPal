"""Account lifecycle: registration, verification, login, refresh rotation, codes, deletion, restore.

Registration never reveals whether an e-mail is known: it always answers the
same and mails either a verification code (new address) or an "account
already exists" notice (known address). Verifying the code is the first
login. Codes are capped per account and purpose, and wrong guesses are
budgeted per account across codes, so requesting new codes does not buy new
guesses.

Deletion has a grace period (ADR 0010): a *pending* account gets no token from any path.
The check lives in :meth:`AuthService._issue_tokens` and :meth:`AuthService.refresh`, both
under the user row lock that ``DELETE /v1/me`` also takes, so a login racing the request
either finishes first (and its refresh token is revoked by the request) or sees the account
pending. Lock order: user row first, then token rows, then the journal lock.
"""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta
from typing import NoReturn

from redis.asyncio import Redis
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql.elements import ColumnElement

from app.config import Settings
from app.db.models import RefreshToken, User
from app.domain.passwords import has_usable_password
from app.email import EmailSender
from app.errors import AppError
from app.observability import get_logger
from app.schemas.auth import RegisterRequest, TokenPair
from app.security import (
    PasswordHasher,
    TokenService,
    hash_refresh_token,
    new_refresh_token,
)
from app.services import account_deletion
from app.services.accounts import create_account
from app.services.auth_errors import (
    account_pending_deletion,
    invalid_code,
    invalid_credentials,
    invalid_token,
    wrong_region,
)
from app.services.auth_password_change import AuthPasswordChange
from app.services.auth_refresh import AuthRefresh
from app.services.changes import lock_journal
from app.services.consents import validate_registration_consents
from app.services.devices import touch_device
from app.services.exports import expire_exports_of_families
from app.services.oauth_pending import attach_pending_identity
from app.services.oauth_state import OAuthState
from app.services.push_tokens import delete_user_tokens
from app.services.refresh_reuse import RefreshReuse
from app.services.restore_tickets import RestoreTickets, cycle_of
from app.services.users import lock_user

_log = get_logger("pillpal.auth")


def _now() -> datetime:
    return datetime.now(UTC)


async def wait_past_password_change(user: User) -> None:
    """Mint no access token in the second of a password change: ``app.deps`` refuses tokens
    issued in or before that second (``iat`` has whole seconds), so a pair minted in it would be
    dead on arrival. Waits at most one second, only right after a change."""
    changed = user.password_changed_at
    if changed is None:
        return
    wait = int(changed.timestamp()) + 1 - datetime.now(UTC).timestamp()
    if wait > 0:
        await asyncio.sleep(wait)


class AuthService(AuthRefresh, AuthPasswordChange):
    def __init__(
        self,
        session: AsyncSession,
        settings: Settings,
        tokens: TokenService,
        hasher: PasswordHasher,
        email_sender: EmailSender,
        redis: Redis,
    ) -> None:
        self.session = session
        self.settings = settings
        self.tokens = tokens
        self.hasher = hasher
        self.email_sender = email_sender
        self.oauth_state = OAuthState(redis, settings)
        self.tickets = RestoreTickets(redis, settings.account_restore_ticket_ttl_seconds)
        self.reuse = RefreshReuse(
            redis,
            settings.refresh_reuse_window_seconds,
            settings.refresh_reuse_redis_timeout_seconds,
        )

    # -- lookups -----------------------------------------------------------

    async def _user_by_email(self, email: str) -> User | None:
        return await self.session.scalar(
            select(User).where(func.lower(User.email) == email.lower())
        )

    # -- tokens ------------------------------------------------------------

    async def _issue_tokens(
        self, user_id: uuid.UUID, device_id: str | None, family_id: uuid.UUID | None = None
    ) -> TokenPair:
        """A new token pair, unless the account is pending deletion (or gone).

        The one place that mints tokens: it locks the user row and re-reads it, so every
        caller (login, verify-email, refresh, restore) is covered at once.
        """
        user = await lock_user(self.session, user_id)
        if user is None:
            raise invalid_token()
        if user.pending_deletion:
            raise account_pending_deletion()
        await wait_past_password_change(user)
        refresh = new_refresh_token()
        family = family_id or uuid.uuid4()
        self.session.add(
            RefreshToken(
                id=uuid.uuid4(),
                user_id=user_id,
                family_id=family,
                token_hash=hash_refresh_token(refresh),
                device_id=device_id,
                expires_at=_now() + timedelta(seconds=self.settings.refresh_token_ttl_seconds),
            )
        )
        return TokenPair(
            access_token=self.tokens.issue_access(user_id, session_id=family),
            refresh_token=refresh,
            expires_in=self.tokens.access_ttl,
        )

    async def _revoke(self, condition: ColumnElement[bool]) -> None:
        # An export belongs to the session that asked: signing out ends it (archive dropped).
        await expire_exports_of_families(
            self.session,
            select(RefreshToken.family_id).where(condition, RefreshToken.revoked_at.is_(None)),
        )
        await self.session.execute(
            update(RefreshToken)
            .where(condition, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=func.now())
        )

    # -- codes -------------------------------------------------------------

    async def register(self, req: RegisterRequest, device_id: str | None) -> None:
        if req.region != self.settings.region:
            raise wrong_region()
        # Before anything depends on the e-mail: the answer must not tell a known address.
        consents = validate_registration_consents(self.settings, req.consents)
        # Hash first in every case so a known address does not answer faster.
        password_hash = await self.hasher.hash(req.password)
        existing = await self._user_by_email(req.email)
        if existing is not None:
            await self._send_known_address_notice(existing)
            return
        user = await self._create_user(req, password_hash, device_id, consents)
        if user is None:  # lost a race against a concurrent registration
            existing = await self._user_by_email(req.email)
            if existing is not None:
                await self._send_known_address_notice(existing)
            return
        code = await self._new_code(user, "verify_email")
        await self.session.commit()
        _log.info("user_registered", user_id=str(user.id))
        await self._send_code(user, "verify_email", code)

    async def _create_user(
        self,
        req: RegisterRequest,
        password_hash: str,
        device_id: str | None,
        consents: list[tuple[str, int]],
    ) -> User | None:
        """Unverified user, self profile and consent records; ``None`` if the e-mail got taken
        (nothing is written then)."""
        return await create_account(
            self.session,
            self.settings,
            email=req.email,
            password_hash=password_hash,
            locale=req.locale,
            timezone=req.timezone,
            display_name=req.display_name,
            consents=consents,
            consent_source="registration",
            device_id=device_id,
            now=_now(),
        )

    async def verify_email(
        self, email: str, code: str, device_id: str | None, pending_token: str | None = None
    ) -> TokenPair:
        """Consume the verification code and log in (first login after registration).

        ``pending_token`` completes the provider link of an OAuth sign-up (ADR 0017 section 5).
        """
        user = await self._user_by_email(email)
        if user is None:
            raise invalid_code()
        await self._consume_code(user.id, "verify_email", code)
        was_verified = user.email_verified_at is not None
        user.email_verified_at = user.email_verified_at or _now()
        await attach_pending_identity(
            self.session,
            self.oauth_state,
            user,
            was_verified=was_verified,
            notify_existing=self._send_known_address_notice,
            notify_not_linked=self._send_not_linked_notice,
            pending_token=pending_token,
            now=_now(),
        )
        await touch_device(self.session, self.settings, user.id, device_id)
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
        await self._warn_if_oauth_pending(user)

    async def _send_not_linked_notice(self, user: User) -> None:
        await self._send_notice(user, "oauth_not_linked")

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
            await self._send_not_linked_notice(user)

    async def login(
        self, email: str, password: str, device_id: str | None, now: datetime
    ) -> TokenPair:
        user = await self._user_by_email(email)
        verified_hash = user.password_hash if user else None
        ok = await self.hasher.verify(verified_hash, password)
        if user is None or not ok:
            _log.info("login_failed")
            raise invalid_credentials()
        # The password may have changed (change or reset) while Argon2 ran: under the row lock
        # the verified hash must still be the current one, else this login used a dead password
        # (and a rehash below must never overwrite the new one).
        locked = await lock_user(self.session, user.id)
        if locked is None or locked.password_hash != verified_hash:
            _log.info("login_failed")
            raise invalid_credentials()
        user = locked
        if user.pending_deletion:
            await self._offer_restore(user, now)
        if user.email_verified_at is None:
            # Only after a correct password, so it reveals nothing to a guesser.
            raise AppError(403, "email_not_verified", "Verify the e-mail address first")
        if self.hasher.needs_rehash(user.password_hash):
            user.password_hash = await self.hasher.hash(password)
        await touch_device(self.session, self.settings, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device_id)
        await self.session.commit()
        _log.info("login_succeeded", user_id=str(user.id))
        return tokens

    async def _offer_restore(self, user: User, now: datetime) -> NoReturn:
        """Answer a correct password for a pending account: ticket plus a mailed code.

        Only after the password matched, so it reveals nothing to a guesser. After
        ``erase_after`` the account is as good as gone (the job just has not run yet).
        """
        if (
            user.erase_after is None
            or user.deletion_requested_at is None
            or user.erase_after <= now
        ):
            raise invalid_credentials()
        code = await self._new_code_capped(user, "restore_account")
        ticket = await self.tickets.issue(user.id, cycle_of(user.deletion_requested_at))
        await self.session.commit()
        if code is not None:  # at the cap an earlier code may still be valid
            await self._send_code(user, "restore_account", code)
        _log.info("restore_offered", user_id=str(user.id))
        raise account_pending_deletion(
            {"restore_ticket": ticket, "erase_after": user.erase_after.isoformat()}
        )

    async def restore(
        self, ticket: str, code: str | None, device_id: str | None, now: datetime
    ) -> TokenPair:
        """Restore a pending account: the ticket from the login and the mailed code (ADR 0010 §2).

        Every failure is the same ``invalid_token``. A wrong code does not spend the
        ticket (a typo is not fatal); the per-account code budget bounds the guesses.
        """
        found = await self.tickets.owner(ticket)
        if found is None or code is None:
            raise invalid_token()
        user = await lock_user(self.session, found[0])
        if user is None or user.erase_after is None or user.erase_after <= now:
            raise invalid_token()
        # Under the row lock: a ticket of an earlier deletion cycle is dead (checked before the
        # code is consumed, so the refusal spends nothing).
        if user.deletion_requested_at is None or cycle_of(user.deletion_requested_at) != found[1]:
            raise invalid_token()
        try:
            await self._consume_code(user.id, "restore_account", code)
        except AppError as exc:
            if exc.code != "invalid_code":
                raise
            raise invalid_token() from None
        await lock_journal(self.session, [user.id])
        await account_deletion.apply_restore(self.session, user, now)
        held = await account_deletion.grants_held_by(self.session, user.id)
        await account_deletion.enqueue_link_restored(self.session, grants=held, now=now)
        await touch_device(self.session, self.settings, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device_id)
        await self.session.commit()
        await self.tickets.spend(ticket)
        await self._send_notice(user, "account_restored")
        return tokens

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
        await delete_user_tokens(self.session, user.id)
        await self.session.commit()
        _log.info("password_reset", user_id=str(user.id))
        await self._send_notice(user, "password_changed")

    async def delete_account(self, user: User, now: datetime) -> None:
        """Start the grace period (nothing is erased yet). The caller has re-authenticated the
        user (``Reauthenticator``: password or a linked provider, ADR 0017 section 8).

        Apple is not asked here: the worker sweep revokes the stored refresh token of a pending
        account (``app.services.provider_tokens``, ADR 0017 section 9)."""
        erase_after = await account_deletion.request_deletion(
            self.session, self.settings, user.id, now
        )
        await self.session.commit()
        _log.info("account_deletion_requested", user_id=str(user.id))
        await self._send_notice(user, "deletion_requested", erase_after)
