"""Re-authentication before a sensitive action (ADR 0017 section 8, ADR 0016 section 8).

Account deletion, data export, identity link and unlink all ask for the same proof: the account
password, or a fresh assertion of a sign-in provider already linked to the account. The check
never reveals which part failed beyond the two stable codes: ``invalid_password`` (401) for the
password form and ``invalid_provider_token`` (401) for the assertion form.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.identities import AuthIdentity
from app.db.models import User
from app.errors import unauthorized
from app.oauth.errors import invalid_provider_token
from app.oauth.registry import ProviderRegistry
from app.schemas.reauth import ReauthAssertion, ReauthProof
from app.security import PasswordHasher
from app.services.oauth_state import OAuthState
from app.services.oauth_verify import REPLAY_SKEW_SECONDS, verify_assertion


class Reauthenticator:
    def __init__(
        self,
        session: AsyncSession,
        settings: Settings,
        hasher: PasswordHasher,
        state: OAuthState,
        providers: ProviderRegistry,
    ) -> None:
        self._session = session
        self._settings = settings
        self._hasher = hasher
        self._state = state
        self._providers = providers

    async def check(self, user: User, proof: ReauthProof, now: datetime) -> None:
        """Raise 401 unless ``proof`` is valid for ``user``; the schema guarantees exactly one."""
        if proof.password is not None:
            if not await self._hasher.verify(user.password_hash, proof.password):
                raise unauthorized("invalid_password", "Wrong password")
            return
        if proof.reauth is None:  # unreachable through the schema; fail closed all the same
            raise invalid_provider_token()
        await self._check_assertion(user, proof.reauth, now)

    async def _check_assertion(self, user: User, form: ReauthAssertion, now: datetime) -> None:
        provider = self._providers.get(form.provider, form.platform, for_reauth=True)
        if provider is None:
            raise invalid_provider_token()
        identity = await verify_assertion(
            self._state,
            self._settings,
            provider,
            assertion=form.assertion,
            nonce=form.nonce,
            platform=form.platform,
            code_verifier=form.code_verifier,
            device_id=form.device_id,
            purpose="reauth",
            now=now,
        )
        if not self._is_fresh(identity.issued_at, now):
            raise invalid_provider_token()
        # Scoped to the caller: an identity of another account is the same refusal as an unknown.
        linked = await self._session.scalar(
            select(AuthIdentity.id).where(
                AuthIdentity.user_id == user.id,
                AuthIdentity.provider == identity.provider,
                AuthIdentity.subject == identity.subject,
            )
        )
        if linked is None:
            raise invalid_provider_token()

    def _is_fresh(self, issued_at: datetime, now: datetime) -> bool:
        age = now - issued_at
        # A little skew into the future is tolerated, an old assertion is not.
        return (
            -timedelta(seconds=REPLAY_SKEW_SECONDS)
            <= age
            <= timedelta(seconds=self._settings.oauth_reauth_max_age_seconds)
        )
