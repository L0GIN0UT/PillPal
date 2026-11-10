"""Linked sign-in identities of the signed-in account (ADR 0017 section 6).

Link and unlink need the re-authentication of ADR 0017 section 8 and mail a notice that names the
provider only. Unlinking the last sign-in method is refused: a password counts only when the
account has one. The provider's ``subject`` is never returned, logged or mailed.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import and_, func, select
from sqlalchemy.exc import IntegrityError

from app.db.identities import AuthIdentity
from app.db.models import RefreshToken, User
from app.domain.passwords import has_usable_password
from app.errors import not_found, unauthorized
from app.oauth.base import VerifiedIdentity
from app.oauth.errors import identity_in_use, last_sign_in_method
from app.observability import get_logger
from app.schemas.identities import IdentityOut, LinkIdentityRequest
from app.schemas.reauth import ReauthProof
from app.services.oauth_sign_in import OAuthService
from app.services.oauth_verify import verify_assertion
from app.services.reauth import Reauthenticator
from app.services.users import lock_user

_log = get_logger("pillpal.oauth")


class IdentityService(OAuthService):
    @property
    def _reauth(self) -> Reauthenticator:
        return Reauthenticator(
            self.session, self.settings, self.hasher, self.oauth_state, self.providers
        )

    async def list_identities(self, user: User) -> list[IdentityOut]:
        rows = await self.session.scalars(
            select(AuthIdentity)
            .where(AuthIdentity.user_id == user.id)
            .order_by(AuthIdentity.created_at, AuthIdentity.id)
        )
        return [IdentityOut.model_validate(row) for row in rows]

    async def link(
        self, user: User, req: LinkIdentityRequest, session_id: uuid.UUID, now: datetime
    ) -> tuple[IdentityOut, bool]:
        """Link the verified identity; ``False`` when it already was linked to this account."""
        provider = self.providers.get(req.provider, req.platform)
        if provider is None:
            raise not_found()
        user_id = user.id
        # The proof of the signed-in account first: a bad one spends nothing of the new assertion.
        await self._reauth.check(user, req, now)
        verified = await verify_assertion(
            self.oauth_state,
            self.settings,
            provider,
            assertion=req.assertion,
            nonce=req.nonce,
            platform=req.platform,
            code_verifier=req.code_verifier,
            purpose="link",
            now=now,
        )
        locked = await self._lock_active(user_id)
        existing = await self._by_subject(verified)
        if existing is not None:
            return self._already_linked(existing, user_id)
        row = self._new_identity(user_id, verified, now)
        try:
            # A savepoint: losing a race for the identity must leave the transaction usable.
            async with self.session.begin_nested():
                self.session.add(row)
        except IntegrityError:
            existing = await self._by_subject(verified)
            if existing is None:
                raise identity_in_use() from None
            return self._already_linked(existing, user_id)
        out = IdentityOut.model_validate(row)
        await self._end_other_sessions(user_id, session_id)
        await self.session.commit()
        _log.info("identity_linked", user_id=str(user_id), provider=verified.provider)
        await self._send_notice(locked, "identity_linked", provider=verified.provider)
        return out, True

    async def unlink(
        self,
        user: User,
        identity_id: uuid.UUID,
        proof: ReauthProof,
        session_id: uuid.UUID,
        now: datetime,
    ) -> None:
        await self._reauth.check(user, proof, now)
        locked = await self._lock_active(user.id)  # serialises concurrent unlinks
        row = await self.session.scalar(
            select(AuthIdentity).where(
                AuthIdentity.id == identity_id, AuthIdentity.user_id == locked.id
            )
        )
        if row is None:
            raise not_found()
        linked = await self.session.scalar(
            select(func.count()).select_from(AuthIdentity).where(AuthIdentity.user_id == locked.id)
        )
        # What remains must still sign the owner in: other identities, or a real password.
        remaining = (linked or 0) - 1 + (1 if has_usable_password(locked.password_hash) else 0)
        if remaining < 1:
            raise last_sign_in_method()
        provider, stored_token = row.provider, row.provider_refresh_token_enc
        await self.session.delete(row)
        await self._end_other_sessions(locked.id, session_id)
        await self.session.commit()
        _log.info("identity_unlinked", user_id=str(locked.id), provider=provider)
        await self._revoke_provider_token(provider, stored_token)
        await self._send_notice(locked, "identity_unlinked", provider=provider)

    async def _lock_active(self, user_id: uuid.UUID) -> User:
        """The locked user row; an account that went pending deletion meanwhile is refused."""
        locked = await lock_user(self.session, user_id)
        if locked is None or locked.pending_deletion:
            raise unauthorized()
        return locked

    async def _end_other_sessions(self, user_id: uuid.UUID, keep: uuid.UUID) -> None:
        """Every refresh family but the caller's ends (and exports of those sessions expire): a
        session opened through a method that was just removed, or by a thief who added one, must
        not outlive the change. Access tokens of those sessions die within their short TTL."""
        await self._revoke(and_(RefreshToken.user_id == user_id, RefreshToken.family_id != keep))

    async def _revoke_provider_token(self, provider: str, stored_token: bytes | None) -> None:
        """TODO(5.8): unlinking an Apple identity revokes Apple's refresh token (best effort, one
        retry, ADR 0017 section 9). Nothing is stored before milestone 5.8, so this does nothing."""

    async def _by_subject(self, verified: VerifiedIdentity) -> AuthIdentity | None:
        return await self.session.scalar(
            select(AuthIdentity).where(
                AuthIdentity.provider == verified.provider,
                AuthIdentity.subject == verified.subject,
            )
        )

    @staticmethod
    def _already_linked(row: AuthIdentity, user_id: uuid.UUID) -> tuple[IdentityOut, bool]:
        if row.user_id != user_id:
            raise identity_in_use()
        return IdentityOut.model_validate(row), False

    @staticmethod
    def _new_identity(
        user_id: uuid.UUID, verified: VerifiedIdentity, now: datetime
    ) -> AuthIdentity:
        return AuthIdentity(
            id=uuid.uuid4(),
            user_id=user_id,
            provider=verified.provider,
            subject=verified.subject,
            email_at_link=verified.email if verified.email_verified else None,
            created_at=now,
            last_used_at=now,
        )
