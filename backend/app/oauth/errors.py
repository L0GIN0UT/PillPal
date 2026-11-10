"""Stable error factories of the OAuth flows (codes are part of the API contract)."""

from __future__ import annotations

from app.errors import AppError, not_found, unauthorized

__all__ = [
    "invalid_provider_token",
    "not_found",
    "oauth_account_exists",
    "provider_unreachable",
    "signup_required",
]


def invalid_provider_token() -> AppError:
    """Bad, replayed, expired or wrong-nonce assertion; also an unknown, used or stale ticket."""
    return unauthorized("invalid_provider_token", "The sign-in could not be verified")


def provider_unreachable() -> AppError:
    """The provider timed out, or the replay and nonce store is down: never accept without it."""
    return AppError(503, "provider_unreachable", "Sign-in is temporarily unavailable, retry")


def oauth_account_exists() -> AppError:
    return AppError(
        409,
        "oauth_account_exists",
        "An account with this address exists; sign in with its method and link the provider",
    )


def signup_required(ticket: str, *, email_required: bool) -> AppError:
    return AppError(
        409,
        "oauth_signup_required",
        "No account yet; finish sign-up with the ticket",
        details={"signup_ticket": ticket, "email_required": email_required},
    )
