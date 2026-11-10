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
from app.errors import not_found, validation_failed
from app.oauth.base import IdentityProvider, VerifiedIdentity
from app.oauth.errors import invalid_provider_token, oauth_account_exists, signup_required
from app.oauth.registry import ProviderRegistry
from app.observability import get_logger
from app.schemas.auth import TokenPair, VerificationSent
from app.schemas.oauth import OAuthSignInRequest, OAuthSignUpRequest
from app.security import PasswordHasher, TokenService
from app.services.accounts import create_account
from app.services.auth import AuthService
from app.services.consents import validate_registration_consents
from app.services.devices import touch_device
from app.services.erasure import erase_account
from app.services.oauth_state import PendingIdentity, SignupTicket
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
            return await self._sign_in_known(row, device_id, now)
        email = identity.email.lower() if identity.email and identity.email_verified else None
        if email is not None:
            existing = await self._user_by_email(email)
            # Only a verified account counts: an unverified password-only row proved nothing
            # (the sign-up replaces it).
            if existing is not None and existing.email_verified_at is not None:
                raise oauth_account_exists()
        ticket = SignupTicket(
            provider=identity.provider,
            subject=identity.subject,
            email=email,
            email_verified=email is not None,
            region=self.settings.region,
            platform=req.platform,
        )
        raise signup_required(
            await self.oauth_state.issue_ticket(ticket), email_required=ticket.email_required
        )

    async def _verify(
        self, provider: IdentityProvider, req: OAuthSignInRequest, purpose: str, now: datetime
    ) -> VerifiedIdentity:
        """Spend the nonce, verify the assertion, claim it in the replay set."""
        nonce = req.nonce
        if provider.uses_nonce and (
            nonce is None or not await self.oauth_state.take_nonce(nonce, purpose)
        ):
            raise invalid_provider_token()
        identity = await provider.verify(
            req.assertion,
            nonce=nonce,
            platform=req.platform,
            code_verifier=req.code_verifier,
            now=now,
        )
        lifetime = int((identity.expires_at - now).total_seconds()) + 1
        if not await self.oauth_state.claim_assertion(
            identity.provider, identity.assertion_id, lifetime
        ):
            raise invalid_provider_token()
        return identity

    async def _sign_in_known(
        self, row: AuthIdentity, device_id: str | None, now: datetime
    ) -> TokenPair:
        user = await lock_user(self.session, row.user_id)
        if user is None:
            raise invalid_provider_token()
        if user.pending_deletion:
            # The assertion alone never restores: ticket plus a mailed code (ADR 0010 section 2).
            await self._offer_restore(user, now)
        row.last_used_at = now
        await touch_device(self.session, self.settings, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device_id)
        await self.session.commit()
        _log.info("oauth_signed_in", user_id=str(user.id), provider=row.provider)
        return tokens

    # -- sign-up -----------------------------------------------------------

    async def sign_up(
        self, req: OAuthSignUpRequest, device_id: str | None, now: datetime
    ) -> TokenPair | VerificationSent:
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
        if ticket is None or not self._ticket_is_current(ticket):
            raise invalid_provider_token()
        if ticket.email is not None and ticket.email_verified:
            return await self._sign_up_verified(ticket, ticket.email, req, consents, device_id, now)
        if req.email is None:  # only when the ticket changed between the peek and the take
            raise invalid_provider_token()
        return await self._sign_up_unverified(ticket, req.email, req, consents, device_id, now)

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
        self.session.add(
            AuthIdentity(
                id=uuid.uuid4(),
                user_id=user.id,
                provider=ticket.provider,
                subject=ticket.subject,
                email_at_link=email,
                created_at=now,
                last_used_at=now,
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
        """A verified provider sign-up replaces a password-only row nobody ever verified.

        Its password was never proven, so it must not block the real owner. A verified row is
        refused (409): the user signs in with it and links the provider.
        """
        existing = await self._user_by_email(email)
        if existing is None:
            return
        locked = await lock_user(self.session, existing.id)
        if locked is None:
            return
        if locked.email_verified_at is not None:
            raise oauth_account_exists()
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
    ) -> VerificationSent:
        """No verified address: mail a code; the identity is attached when it is entered."""
        existing = await self._user_by_email(email)
        if existing is None:
            user = await self._new_user(email, req, consents, device_id, now, verified=False)
            if user is not None:
                code = await self._new_code(user, "verify_email")
                pending = PendingIdentity(
                    email=email, provider=ticket.provider, subject=ticket.subject
                )
                # Before the commit: without Redis nothing is created and the user retries.
                await self.oauth_state.store_pending(
                    user.id, pending, self.settings.email_code_ttl_seconds
                )
                await self.session.commit()
                await self._send_code(user, "verify_email", code)
                return VerificationSent()
            existing = await self._user_by_email(email)  # lost a race for the address
        if existing is not None:
            await self._send_known_address_notice(existing)
        return VerificationSent()

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
