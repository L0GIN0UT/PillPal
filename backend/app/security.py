"""Password hashing (Argon2id), access JWTs, opaque refresh tokens, one-time codes."""

from __future__ import annotations

import hashlib
import hmac
import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import anyio
import jwt
from argon2 import PasswordHasher as _Argon2
from argon2 import Type
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

from app.config import Settings

ACCESS_TOKEN_TYPE = "access"  # noqa: S105 - JWT "typ" claim, not a secret
JWT_ALGORITHM = "HS256"


class PasswordHasher:
    """Argon2id hashing off the event loop (hashing is deliberately CPU-heavy)."""

    def __init__(self, settings: Settings) -> None:
        self._hasher = _Argon2(
            time_cost=settings.password_hash_time_cost,
            memory_cost=settings.password_hash_memory_kib,
            parallelism=settings.password_hash_parallelism,
            type=Type.ID,
        )
        # Verified against when the account does not exist, so "unknown e-mail"
        # and "wrong password" take the same time.
        self._dummy_hash = self._hasher.hash(secrets.token_urlsafe(16))

    async def hash(self, password: str) -> str:
        return await anyio.to_thread.run_sync(self._hasher.hash, password)

    async def verify(self, password_hash: str | None, password: str) -> bool:
        target = password_hash or self._dummy_hash

        def _verify() -> bool:
            try:
                return self._hasher.verify(target, password)
            except (VerifyMismatchError, VerificationError, InvalidHashError):
                return False

        ok = await anyio.to_thread.run_sync(_verify)
        return ok and password_hash is not None

    def needs_rehash(self, password_hash: str) -> bool:
        return self._hasher.check_needs_rehash(password_hash)


@dataclass(frozen=True)
class AccessClaims:
    user_id: uuid.UUID


class TokenService:
    def __init__(self, settings: Settings) -> None:
        self._secret = settings.jwt_secret.get_secret_value()
        self._region = settings.region
        self._ttl = settings.access_token_ttl_seconds
        self._code_key = hmac.new(
            self._secret.encode(), b"pillpal/email-code", hashlib.sha256
        ).digest()

    @property
    def access_ttl(self) -> int:
        return self._ttl

    def issue_access(self, user_id: uuid.UUID, now: datetime | None = None) -> str:
        now = now or datetime.now(UTC)
        claims: dict[str, Any] = {
            "sub": str(user_id),
            "region": self._region,
            "typ": ACCESS_TOKEN_TYPE,
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(seconds=self._ttl)).timestamp()),
            "jti": uuid.uuid4().hex,
        }
        return jwt.encode(claims, self._secret, algorithm=JWT_ALGORITHM)

    def decode_access(self, token: str) -> AccessClaims | None:
        try:
            claims = jwt.decode(
                token,
                self._secret,
                algorithms=[JWT_ALGORITHM],
                options={"require": ["exp", "iat", "sub"]},
            )
            if claims.get("typ") != ACCESS_TOKEN_TYPE or claims.get("region") != self._region:
                return None
            return AccessClaims(user_id=uuid.UUID(str(claims["sub"])))
        except (jwt.PyJWTError, ValueError):
            return None

    def code_hash(self, user_id: uuid.UUID, purpose: str, code: str) -> str:
        # Keyed hash: 6-digit codes are trivially brute-forced from a plain hash.
        msg = f"{user_id}:{purpose}:{code}".encode()
        return hmac.new(self._code_key, msg, hashlib.sha256).hexdigest()


def new_refresh_token() -> str:
    return secrets.token_urlsafe(32)


def hash_refresh_token(token: str) -> str:
    # Refresh tokens carry 256 bits of entropy; a fast hash is sufficient.
    return hashlib.sha256(token.encode()).hexdigest()


def new_numeric_code() -> str:
    return f"{secrets.randbelow(10**6):06d}"


def constant_time_equals(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode(), b.encode())
