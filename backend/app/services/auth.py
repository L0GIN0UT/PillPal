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

import uuid
from datetime import UTC, datetime, timedelta
from typing import NoReturn

from redis.asyncio import Redis
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql.elements import ColumnElement

from app.config import Settings
from app.db.models import Profile, RefreshToken, User
from app.email import EmailSender
from app.errors import AppError, unauthorized
from app.observability import get_logger
from app.schemas.auth import RegisterRequest, TokenPair
from app.security import (
    PasswordHasher,
    TokenService,
    hash_refresh_token,
    new_refresh_token,
)
from app.services import account_deletion
from app.services.account_deletion import lock_user
from app.services.auth_errors import (
    account_pending_deletion,
    invalid_code,
    invalid_credentials,
    invalid_token,
    wrong_region,
)
from app.services.auth_mail import AuthMail
from app.services.changes import lock_journal, record_change
from app.services.devices import touch_device
from app.services.push_tokens import delete_device_token, delete_family_tokens, delete_user_tokens
from app.services.refresh_reuse import RefreshReuse
from app.services.restore_tickets import RestoreTickets, cycle_of

_log = get_logger("pillpal.auth")

DEFAULT_SELF_DISPLAY_NAME = "Me"


def _now() -> datetime:
    return datetime.now(UTC)


class AuthService(AuthMail):
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

    async def register(self, req: RegisterRequest, device_id: str | None) -> None:
        if req.region != self.settings.region:
            raise wrong_region()
        # Hash first in every case so a known address does not answer faster.
        password_hash = await self.hasher.hash(req.password)
        existing = await self._user_by_email(req.email)
        if existing is not None:
            await self._send_known_address_notice(existing)
            return
        user = await self._create_user(req, password_hash, device_id)
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
        await lock_journal(self.session, [user.id])
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
        await record_change(self.session, profile.id, "profile", profile.id, "upsert")
        await touch_device(self.session, self.settings, user.id, device_id)
        return user

    async def verify_email(self, email: str, code: str, device_id: str | None) -> TokenPair:
        """Consume the verification code and log in (first login after registration)."""
        user = await self._user_by_email(email)
        if user is None:
            raise invalid_code()
        await self._consume_code(user.id, "verify_email", code)
        user.email_verified_at = user.email_verified_at or _now()
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

    async def login(
        self, email: str, password: str, device_id: str | None, now: datetime
    ) -> TokenPair:
        user = await self._user_by_email(email)
        ok = await self.hasher.verify(user.password_hash if user else None, password)
        if user is None or not ok:
            _log.info("login_failed")
            raise invalid_credentials()
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

    async def refresh(
        self, token: str, device_id: str | None, now: datetime | None = None
    ) -> TokenPair:
        now = now or _now()
        found = await self.session.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(token))
        )
        if found is None:
            raise invalid_token()
        # The user row first (like every other path), then the token row: ``DELETE /v1/me``
        # locks the user and then revokes the tokens, so the other order could deadlock.
        user = await lock_user(self.session, found.user_id)
        row = await self.session.scalar(
            select(RefreshToken)
            .where(RefreshToken.id == found.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        if row is None or user is None:
            raise invalid_token()
        if row.used_at is not None:
            return await self._repeat_of_rotated(row, user, token, device_id, now)
        if row.revoked_at is not None or row.expires_at <= now or user.pending_deletion:
            raise invalid_token()
        row.used_at = now
        device = device_id or row.device_id
        await touch_device(self.session, self.settings, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device, family_id=row.family_id)
        # Before the commit and under the row lock: a repeat waiting for the lock finds it.
        # If the commit fails the repeat sees an unrotated token and never reads the entry.
        await self.reuse.remember(token, device, tokens.model_dump())
        await self.session.commit()
        return tokens

    async def _repeat_of_rotated(
        self, row: RefreshToken, user: User, token: str, device_id: str | None, now: datetime
    ) -> TokenPair:
        """A rotated token came back: the same device within the window gets the same pair,
        anything else is theft and kills the whole family."""
        window = timedelta(seconds=self.settings.refresh_reuse_window_seconds)
        alive = row.revoked_at is None and row.expires_at > now and not user.pending_deletion
        if alive and row.used_at is not None and now - row.used_at <= window:
            pair = await self.reuse.recall(token, device_id)
            if pair is not None and await self._child_is_unspent(row, pair):
                return TokenPair.model_validate(pair)
        await self._revoke(RefreshToken.family_id == row.family_id)
        # A stolen session must not keep receiving alerts about relatives.
        await delete_family_tokens(self.session, row.user_id, row.family_id)
        await self.session.commit()
        _log.warning("refresh_token_reuse_detected", user_id=str(row.user_id))
        raise unauthorized("token_reused", "Refresh token reuse detected; session revoked")

    async def _child_is_unspent(self, row: RefreshToken, pair: dict[str, object]) -> bool:
        """The cached pair's refresh token is still the live head of the family.

        A lost response never saw it; if it was rotated or revoked since, the repeat of the
        old token is not a retry.
        """
        issued = pair.get("refresh_token")
        if not isinstance(issued, str):
            return False
        child = await self.session.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(issued))
        )
        return (
            child is not None
            and child.family_id == row.family_id
            and child.used_at is None
            and child.revoked_at is None
        )

    async def logout(self, token: str) -> None:
        row = await self.session.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(token))
        )
        if row is not None:
            await self._revoke(RefreshToken.family_id == row.family_id)
            if row.device_id is not None:
                # Signed out: this device no longer needs alerts about relatives.
                await delete_device_token(self.session, row.user_id, row.device_id)
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
        await delete_user_tokens(self.session, user.id)
        await self.session.commit()
        _log.info("password_reset", user_id=str(user.id))

    async def delete_account(self, user: User, password: str, now: datetime) -> None:
        """Start the grace period after re-checking the password (nothing is erased yet)."""
        if not await self.hasher.verify(user.password_hash, password):
            raise unauthorized("invalid_password", "Wrong password")
        erase_after = await account_deletion.request_deletion(
            self.session, self.settings, user.id, now
        )
        await self.session.commit()
        _log.info("account_deletion_requested", user_id=str(user.id))
        await self._send_notice(user, "deletion_requested", erase_after)
