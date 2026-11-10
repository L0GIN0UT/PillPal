"""Short-lived OAuth state in Redis (ADR 0017 sections 3 to 5). Every key is hashed and has a TTL.

* ``oc:`` server nonces: 256 random bits, bound to a purpose, single use (``GETDEL``).
* ``ot:`` sign-up tickets (the verified provider identity, bound to region and platform) and the
  pending identity of the e-mail fallback (bound to e-mail, provider and subject, with the TTL of
  the mailed code). Different hashed inputs, so the two cannot collide.
* ``on:`` replay set: an assertion is accepted only if its ``SET NX`` succeeds.

Unlike the rate limiter this fails closed: without Redis nothing is accepted and the caller gets
503 ``provider_unreachable``. None of these values is ever logged.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import uuid
from collections.abc import Awaitable
from dataclasses import asdict, dataclass
from typing import Any, TypeVar, cast

from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.config import Settings
from app.oauth.errors import provider_unreachable

NONCE_PREFIX = "oc:"
TICKET_PREFIX = "ot:"
REPLAY_PREFIX = "on:"
NONCE_BYTES = 32  # 256 bits; the floor is 128
TICKET_BYTES = 32
NONCE_PURPOSES = ("sign_in", "link", "reauth")
PENDING_TOKEN_BYTES = 32

_T = TypeVar("_T")


def _digest(*parts: str) -> str:
    return hashlib.sha256("\x00".join(parts).encode()).hexdigest()


@dataclass(frozen=True)
class SignupTicket:
    """What a sign-up ticket carries, so sign-up never re-trusts client input about it."""

    provider: str
    subject: str
    email: str | None
    email_verified: bool
    region: str
    platform: str
    # Apple: the identity id the sealed refresh token is bound to (the salt of its key) and the
    # token itself, sealed and hex-encoded (never plaintext in Redis). Both ``None`` otherwise.
    identity_id: str | None = None
    refresh_token_enc: str | None = None

    @property
    def email_required(self) -> bool:
        return not (self.email_verified and self.email)

    def bound_token(self) -> tuple[uuid.UUID, bytes] | None:
        """The identity id and sealed refresh token the sign-up must store, when there is one."""
        if self.identity_id is None or self.refresh_token_enc is None:
            return None
        try:
            return uuid.UUID(self.identity_id), bytes.fromhex(self.refresh_token_enc)
        except ValueError:
            return None


@dataclass(frozen=True)
class PendingIdentity:
    """An identity waiting for its e-mail to be verified (the fallback)."""

    email: str
    provider: str
    subject: str
    # sha256 of the ``pending_token`` the 202 answer gave to the client that started the fallback:
    # only that client can complete the link (a code proves the mailbox, not who began).
    token_hash: str

    def matches_token(self, token: str | None) -> bool:
        return token is not None and hmac.compare_digest(self.token_hash, hash_pending_token(token))


def new_pending_token() -> str:
    return secrets.token_urlsafe(PENDING_TOKEN_BYTES)


def hash_pending_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class OAuthState:
    def __init__(self, redis: Redis, settings: Settings) -> None:
        self._redis = redis
        self._nonce_ttl = settings.oauth_nonce_ttl_seconds
        self._ticket_ttl = settings.oauth_signup_ticket_ttl_seconds

    # -- nonces ------------------------------------------------------------

    async def issue_nonce(self, purpose: str) -> str:
        nonce = secrets.token_urlsafe(NONCE_BYTES)
        await self._run(self._redis.set(NONCE_PREFIX + _digest(nonce), purpose, ex=self._nonce_ttl))
        return nonce

    async def take_nonce(self, nonce: str, purpose: str) -> bool:
        """Consume the nonce; ``True`` only if it is live and was issued for ``purpose``."""
        found = await self._run(self._redis.getdel(NONCE_PREFIX + _digest(nonce)))
        return found is not None and _text(found) == purpose

    # -- replay ------------------------------------------------------------

    async def claim_assertion(self, provider: str, assertion_id: str, ttl_seconds: int) -> bool:
        """``True`` for the first claim of this assertion, ``False`` for a replay."""
        key = REPLAY_PREFIX + _digest(provider, assertion_id)
        return bool(await self._run(self._redis.set(key, "1", ex=max(1, ttl_seconds), nx=True)))

    # -- sign-up tickets ---------------------------------------------------

    async def issue_ticket(self, ticket: SignupTicket) -> str:
        token = secrets.token_urlsafe(TICKET_BYTES)
        await self._run(
            self._redis.set(
                TICKET_PREFIX + _digest(token), json.dumps(asdict(ticket)), ex=self._ticket_ttl
            )
        )
        return token

    async def peek_ticket(self, token: str) -> SignupTicket | None:
        """Read without consuming: the body is validated before the ticket is spent."""
        return _ticket(await self._run(self._redis.get(TICKET_PREFIX + _digest(token))))

    async def take_ticket(self, token: str) -> SignupTicket | None:
        return _ticket(await self._run(self._redis.getdel(TICKET_PREFIX + _digest(token))))

    # -- the e-mail fallback -----------------------------------------------

    async def store_pending(self, user_id: uuid.UUID, pending: PendingIdentity, ttl: int) -> None:
        await self._run(
            self._redis.set(_pending_key(user_id), json.dumps(asdict(pending)), ex=max(1, ttl))
        )

    async def has_pending(self, user_id: uuid.UUID) -> bool:
        return bool(await self._run(self._redis.exists(_pending_key(user_id))))

    async def take_pending(self, user_id: uuid.UUID) -> PendingIdentity | None:
        raw = await self._run(self._redis.getdel(_pending_key(user_id)))
        data = _loads(raw)
        if data is None:
            return None
        try:
            return PendingIdentity(**data)
        except TypeError:
            return None

    async def _run(self, call: Awaitable[_T] | _T) -> _T:
        try:
            return await cast("Awaitable[_T]", call)
        except (RedisError, OSError):
            raise provider_unreachable() from None


def _pending_key(user_id: uuid.UUID) -> str:
    return TICKET_PREFIX + _digest("pending", str(user_id))


def _text(value: bytes | str) -> str:
    return value.decode() if isinstance(value, bytes) else value


def _loads(raw: bytes | str | None) -> dict[str, Any] | None:
    if raw is None:
        return None
    try:
        data = json.loads(_text(raw))
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def _ticket(raw: bytes | str | None) -> SignupTicket | None:
    data = _loads(raw)
    if data is None:
        return None
    try:
        return SignupTicket(**data)
    except TypeError:
        return None
