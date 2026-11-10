"""The password hash of an account that has no password (OAuth-only), ADR 0017 section 7.

The sentinel is not an Argon2 string, so it can never verify: ``PasswordHasher`` recognises it
before the Argon2 parser runs. ``users.password_hash`` stays NOT NULL (no migration on ``users``).
Pure: no IO.
"""

from __future__ import annotations

UNUSABLE_PASSWORD_HASH = "!oauth-no-password"  # noqa: S105 - a marker, not a credential


def has_usable_password(password_hash: str) -> bool:
    return password_hash != UNUSABLE_PASSWORD_HASH
