"""Verify one provider assertion: spend the nonce, check the token, claim it in the replay set.

Shared by sign-in, link and re-auth (ADR 0017 section 3). Nothing here is logged.
"""

from __future__ import annotations

from datetime import datetime

from app.config import Settings
from app.oauth.base import IdentityProvider, VerifiedIdentity
from app.oauth.errors import invalid_provider_token
from app.services.oauth_state import OAuthState

# Slack beyond the nonce lifetime for the replay marker (clock skew with the provider).
REPLAY_SKEW_SECONDS = 60


async def verify_assertion(
    state: OAuthState,
    settings: Settings,
    provider: IdentityProvider,
    *,
    assertion: str,
    nonce: str | None,
    platform: str,
    code_verifier: str | None,
    purpose: str,
    now: datetime,
    device_id: str | None = None,
) -> VerifiedIdentity:
    """The nonce is single use and bound to ``purpose``; the assertion is accepted once.

    For a code provider the nonce is the ``state`` of the authorization: spent here, before the
    code is exchanged, so a state of another purpose or a second use never reaches the provider.
    """
    if provider.uses_nonce and (nonce is None or not await state.take_nonce(nonce, purpose)):
        raise invalid_provider_token()
    identity = await provider.verify(
        assertion,
        nonce=nonce,
        platform=platform,
        code_verifier=code_verifier,
        device_id=device_id,
        now=now,
    )
    # Bounded: a provider-chosen far-future ``exp`` must not park a key for days.
    lifetime = min(
        int((identity.expires_at - now).total_seconds()) + 1,
        settings.oauth_nonce_ttl_seconds + REPLAY_SKEW_SECONDS,
    )
    if not await state.claim_assertion(identity.provider, identity.assertion_id, lifetime):
        raise invalid_provider_token()
    return identity
