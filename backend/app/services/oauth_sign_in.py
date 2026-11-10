"""OAuth sign-in and sign-up (ADR 0017 sections 3 to 5).

Sign-in verifies a provider assertion and never merges accounts: a known identity gets tokens
(a pending-deletion account is offered the ADR 0010 restore instead), a verified address that
already has a verified account is a 409, anything else is a 409 with a sign-up ticket. Sign-up
validates the body, spends the ticket, then creates the account (verified address) or starts the
e-mail fallback (no verified address).

Nothing here is logged except opaque ids and the provider name (never a subject, e-mail, token,
nonce or ticket).
"""

from __future__ import annotations

import uuid
from datetime import datetime

from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.identities import AuthIdentity
from app.db.models import User
from app.domain.auth_providers import is_allowed
from app.domain.passwords import UNUSABLE_PASSWORD_HASH
from app.email import EmailSender
from app.errors import AppError, not_found, validation_failed
from app.oauth.base import IdentityProvider, VerifiedIdentity
from app.oauth.errors import invalid_provider_token, oauth_account_exists, signup_required
from app.oauth.registry import ProviderRegistry
from app.observability import get_logger
from app.schemas.auth import OAuthVerificationSent, TokenPair
from app.schemas.oauth import OAuthSignInRequest, OAuthSignUpRequest
from app.security import PasswordHasher, TokenService
from app.services.accounts import create_account
from app.services.auth import AuthService
from app.services.consents import validate_registration_consents
from app.services.devices import touch_device
from app.services.erasure import erase_account
from app.services.oauth_state import (
    PendingIdentity,
    SignupTicket,
    hash_pending_token,
    new_pending_token,
)
from app.services.oauth_verify import verify_assertion
from app.services.users import lock_user

_log = get_logger("pillpal.oauth")


class OAuthService(AuthService):
    def __init__(
        self,
        session: AsyncSession,
        settings: Settings,
        tokens: TokenService,
        hasher: PasswordHasher,
        email_sender: EmailSender,
        redis: Redis,
        providers: ProviderRegistry,
    ) -> None:
        super().__init__(session, settings, tokens, hasher, email_sender, redis)
        self.providers = providers

    # -- sign-in -----------------------------------------------------------

    async def sign_in(
        self, provider_name: str, req: OAuthSignInRequest, device_id: str | None, now: datetime
    ) -> TokenPair:
        provider = self.providers.get(provider_name, req.platform)
        if provider is None:
            raise not_found()
        identity = await self._verify(provider, req, "sign_in", now)
        row = await self.session.scalar(
            select(AuthIdentity).where(
                AuthIdentity.provider == identity.provider,
                AuthIdentity.subject == identity.subject,
            )
        )
        if row is not None:
            sealed = await self._seal_for_known(row, req.authorization_code, now)
            return await self._sign_in_known(row, device_id, now, sealed)
        email = identity.email.lower() if identity.email and identity.email_verified else None
        if email is not None:
            existing = await self._user_by_email(email)
            # Only a verified account counts: an unverified password-only row proved nothing
            # (the sign-up replaces it).
            if existing is not None and existing.email_verified_at is not None:
                raise oauth_account_exists()
        identity_id = uuid.uuid4()
        sealed = await self._exchange(
            identity.provider, req.authorization_code, identity.subject, identity_id, now
        )
        ticket = SignupTicket(
            provider=identity.provider,
            subject=identity.subject,
            email=email,
            email_verified=email is not None,
            region=self.settings.region,
            platform=req.platform,
            identity_id=str(identity_id) if sealed is not None else None,
            refresh_token_enc=sealed.hex() if sealed is not None else None,
        )
        try:
            token = await self.oauth_state.issue_ticket(ticket)
        except AppError:  # Redis is down: the exchanged token would be left behind
            await self._discard(identity.provider, identity_id, sealed, now)
            raise
        raise signup_required(token, email_required=ticket.email_required)

    async def _verify(
        self, provider: IdentityProvider, req: OAuthSignInRequest, purpose: str, now: datetime
    ) -> VerifiedIdentity:
        return await verify_assertion(
            self.oauth_state,
            self.settings,
            provider,
            assertion=req.assertion,
            nonce=req.nonce,
            platform=req.platform,
            code_verifier=req.code_verifier,
            device_id=req.device_id,
            purpose=purpose,
            now=now,
        )

    async def _exchange(
        self,
        provider: str,
        code: str | None,
        subject: str,
        identity_id: uuid.UUID,
        now: datetime,
    ) -> bytes | None:
        """Trade an Apple authorization code for a sealed refresh token (``None``: no code or no
        success). The read transaction ends first: no connection waits on Apple."""
        if not code:
            return None
        await self.session.commit()
        return await self.providers.tokens.exchange_and_seal(
            provider, code, subject, identity_id, now
        )

    async def _discard(
        self, provider: str, identity_id: uuid.UUID, sealed: bytes | None, now: datetime
    ) -> None:
        """A token that will not be stored (lost race, pending account, abandoned flow) is
        revoked at once, best effort with the short inline timeout."""
        if sealed is not None:
            await self.providers.tokens.revoke(provider, identity_id, sealed, now, inline=True)

    async def _seal_for_known(
        self, row: AuthIdentity, code: str | None, now: datetime
    ) -> bytes | None:
        """A refresh token for a known identity that has none (a restored account authorizes
        again, ADR 0017 section 9). Not for an account pending deletion: nothing may be stored
        that the deletion revoke has already ended (re-checked under the lock afterwards)."""
        if not code or row.provider_refresh_token_enc is not None:
            return None
        requested = await self.session.scalar(
            select(User.deletion_requested_at).where(User.id == row.user_id)
        )
        if requested is not None:
            return None
        return await self._exchange(row.provider, code, row.subject, row.id, now)

    async def _sign_in_known(
        self, row: AuthIdentity, device_id: str | None, now: datetime, sealed: bytes | None = None
    ) -> TokenPair:
        user = await lock_user(self.session, row.user_id)
        if user is None:
            raise invalid_provider_token()
        if user.pending_deletion:
            # A request that came in during the exchange: nothing may be stored (and what was
            # exchanged is ended). The assertion alone never restores: ticket plus a mailed code
            # (ADR 0010 section 2).
            await self._discard(row.provider, row.id, sealed, now)
            await self._offer_restore(user, now)
        row.last_used_at = now
        if sealed is not None and row.provider_refresh_token_enc is None:
            row.provider_refresh_token_enc = sealed
        await touch_device(self.session, self.settings, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device_id)
        await self.session.commit()
        _log.info("oauth_signed_in", user_id=str(user.id), provider=row.provider)
        return tokens

    # -- sign-up -----------------------------------------------------------

    async def sign_up(
        self, req: OAuthSignUpRequest, device_id: str | None, now: datetime
    ) -> TokenPair | OAuthVerificationSent:
        # The whole body first, then the ticket: a malformed request does not burn it.
        consents = validate_registration_consents(self.settings, req.consents)
        if req.region != self.settings.region:
            raise validation_failed(("body", "region"), "Must match the region of this server")
        peeked = await self.oauth_state.peek_ticket(req.signup_ticket)
        if peeked is None:
            raise invalid_provider_token()
        if peeked.email_required and req.email is None:
            raise validation_failed(("body", "email"), "An e-mail address is required")
        ticket = await self.oauth_state.take_ticket(req.signup_ticket)
        if ticket is None:
            raise invalid_provider_token()
        if not self._ticket_is_current(ticket):
            await self._discard_ticket_token(ticket, now)
            raise invalid_provider_token()
        if ticket.email is not None and ticket.email_verified:
            try:
                return await self._sign_up_verified(
                    ticket, ticket.email, req, consents, device_id, now
                )
            except AppError:  # nothing was created: the token that rode on the ticket is ended
                await self._discard_ticket_token(ticket, now)
                raise
        # The e-mail fallback stores no provider token (the next sign-in with a code does).
        await self._discard_ticket_token(ticket, now)
        if req.email is None:  # only when the ticket changed between the peek and the take
            raise invalid_provider_token()
        return await self._sign_up_unverified(ticket, req.email, req, consents, device_id, now)

    async def _discard_ticket_token(self, ticket: SignupTicket, now: datetime) -> None:
        bound = ticket.bound_token()
        if bound is not None:
            await self._discard(ticket.provider, bound[0], bound[1], now)

    def _ticket_is_current(self, ticket: SignupTicket) -> bool:
        """Bound to this region and to a platform the provider is still offered on."""
        return (
            ticket.region == self.settings.region
            and is_allowed(self.settings.region, ticket.provider, ticket.platform)
            and self.providers.get(ticket.provider, ticket.platform) is not None
        )

    async def _sign_up_verified(
        self,
        ticket: SignupTicket,
        email: str,
        req: OAuthSignUpRequest,
        consents: list[tuple[str, int]],
        device_id: str | None,
        now: datetime,
    ) -> TokenPair:
        await self._clear_unverified_row(email, now)
        user = await self._new_user(email, req, consents, device_id, now, verified=True)
        if user is None:
            raise oauth_account_exists()
        bound = ticket.bound_token()
        self.session.add(
            AuthIdentity(
                id=bound[0] if bound else uuid.uuid4(),
                user_id=user.id,
                provider=ticket.provider,
                subject=ticket.subject,
                email_at_link=email,
                created_at=now,
                last_used_at=now,
                provider_refresh_token_enc=bound[1] if bound else None,
            )
        )
        try:
            tokens = await self._issue_tokens(user.id, device_id)
            await self.session.commit()
        except IntegrityError:  # the same identity signed up through another ticket
            await self.session.rollback()
            raise oauth_account_exists() from None
        _log.info("oauth_signed_up", user_id=str(user.id), provider=ticket.provider)
        return tokens

    async def _clear_unverified_row(self, email: str, now: datetime) -> None:
        """A verified provider sign-up replaces any unverified row with the same address.

        An unverified row proved nothing: a password nobody confirmed, or the passwordless row of
        an unfinished fallback (its pending entry goes too). It must not block the real owner. A
        verified row is refused (409): the user signs in with it and links the provider.
        """
        existing = await self._user_by_email(email)
        if existing is None:
            return
        locked = await lock_user(self.session, existing.id)
        if locked is None:
            return
        if locked.email_verified_at is not None:
            raise oauth_account_exists()
        await self.oauth_state.take_pending(locked.id)
        await erase_account(
            self.session,
            locked.id,
            now=now,
            managed_archive_retention_days=self.settings.managed_archive_retention_days,
        )

    async def _sign_up_unverified(
        self,
        ticket: SignupTicket,
        email: str,
        req: OAuthSignUpRequest,
        consents: list[tuple[str, int]],
        device_id: str | None,
        now: datetime,
    ) -> OAuthVerificationSent:
        """No verified address: mail a code. The identity is attached when the code comes with
        the ``pending_token`` returned here (only this client holds it)."""
        token = new_pending_token()
        existing = await self._user_by_email(email)
        if existing is None:
            user = await self._new_user(email, req, consents, device_id, now, verified=False)
            if user is not None:
                code = await self._new_code(user, "verify_email")
                pending = PendingIdentity(
                    email=email,
                    provider=ticket.provider,
                    subject=ticket.subject,
                    token_hash=hash_pending_token(token),
                )
                # Before the commit: without Redis nothing is created and the user retries.
                await self.oauth_state.store_pending(
                    user.id, pending, self.settings.email_code_ttl_seconds
                )
                await self.session.commit()
                await self._send_code(user, "verify_email", code)
                return OAuthVerificationSent(pending_token=token)
            existing = await self._user_by_email(email)  # lost a race for the address
        if existing is not None:
            await self._send_known_address_notice(existing)
        return OAuthVerificationSent(pending_token=token)

    async def _new_user(
        self,
        email: str,
        req: OAuthSignUpRequest,
        consents: list[tuple[str, int]],
        device_id: str | None,
        now: datetime,
        *,
        verified: bool,
    ) -> User | None:
        return await create_account(
            self.session,
            self.settings,
            email=email,
            password_hash=UNUSABLE_PASSWORD_HASH,
            locale=req.locale,
            timezone=req.timezone,
            display_name=req.display_name,
            consents=consents,
            consent_source="oauth_signup",
            device_id=device_id,
            now=now,
            verified=verified,
        )
