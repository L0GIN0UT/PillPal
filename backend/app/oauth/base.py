"""The contract of an identity provider (ADR 0017 section 3)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol


@dataclass(frozen=True)
class VerifiedIdentity:
    """What a provider proved. ``email`` counts only with ``email_verified``.

    ``assertion_id`` identifies this one assertion (the ``jti``, or a hash of the token or code)
    and ``expires_at`` is when it stops being acceptable: together they feed the replay set.
    """

    provider: str
    subject: str
    email: str | None
    email_verified: bool
    assertion_id: str
    expires_at: datetime
    # When the provider issued the assertion (``iat``; ``now`` for an authorization code exchanged
    # just now). Re-authentication accepts only a recent one; ``None`` is never recent enough.
    issued_at: datetime | None = None


class IdentityProvider(Protocol):
    name: str
    # Providers that take a nonce (ID token flows) must see the server-issued one.
    uses_nonce: bool

    async def verify(
        self,
        assertion: str,
        *,
        nonce: str | None,
        platform: str,
        code_verifier: str | None,
        now: datetime,
    ) -> VerifiedIdentity:
        """The identity behind ``assertion``.

        Raises ``invalid_provider_token`` for a bad, expired or wrong-nonce assertion and
        ``provider_unreachable`` when the provider cannot be asked. ``nonce`` is the raw server
        nonce (already consumed by the caller): the token must carry its sha256.
        """
        ...
